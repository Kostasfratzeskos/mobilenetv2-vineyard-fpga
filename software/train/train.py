"""Fine-tune MobileNetV2 on the grape-disease dataset and save the best checkpoint.

Run from inside software/:
    python train/train.py --data ../data/grape_leafsplit --out runs/mobilenetv2_grape_leafsplit.pth
    python train/train.py --data ../data/grape_leafsplit --freeze-backbone --epochs 8   # fast / CPU

Trains on train/, picks the checkpoint on val/ (best accuracy, ties to the lower
loss), and never opens test/ - that is evaluate.py's, once. Writes the
checkpoint you'll quantize next and a per-epoch log beside it (<out>.csv). The
checkpoint records which data and settings made it: the deployed one did not,
and nobody could say afterwards what it had been trained on (DD-034).
"""
from __future__ import annotations

import argparse
import csv
import os
import random
import sys
import time

import torch
import torch.nn as nn

# add software/ to the path so the sibling 'model' package is importable; 'dataset'
# is in this same folder, so import it directly (importing it as 'train.dataset'
# clashes with this file, train.py, which shadows the 'train' package)
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from model.mobilenetv2 import build_model, set_backbone_trainable, save_checkpoint  # noqa: E402
from dataset import make_dataloaders, IMAGENET_MEAN, IMAGENET_STD  # noqa: E402


def set_seed(s):
    random.seed(s)
    torch.manual_seed(s)
    torch.cuda.manual_seed_all(s)


def pick_device():
    if torch.cuda.is_available():
        return "cuda"
    mps = getattr(torch.backends, "mps", None)
    if mps is not None and mps.is_available():
        return "mps"
    return "cpu"


def run_epoch(model, loader, device, criterion, optimizer=None, scaler=None):
    is_train = optimizer is not None
    model.train(is_train)
    total, correct, loss_sum = 0, 0, 0.0
    for x, y in loader:
        x = x.to(device, non_blocking=True)
        y = y.to(device, non_blocking=True)
        if is_train:
            optimizer.zero_grad(set_to_none=True)
            if scaler is not None:
                with torch.amp.autocast("cuda"):
                    out = model(x)
                    loss = criterion(out, y)
                scaler.scale(loss).backward()
                scaler.step(optimizer)
                scaler.update()
            else:
                out = model(x)
                loss = criterion(out, y)
                loss.backward()
                optimizer.step()
        else:
            with torch.no_grad():
                out = model(x)
                loss = criterion(out, y)
        bs = y.size(0)
        total += bs
        loss_sum += loss.item() * bs
        correct += (out.argmax(1) == y).sum().item()
    return loss_sum / max(total, 1), correct / max(total, 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", required=True, help="dataset root (ImageFolder or train/val)")
    p.add_argument("--epochs", type=int, default=20)
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--lr", type=float, default=0.01)
    p.add_argument("--weight-decay", type=float, default=4e-5)
    p.add_argument("--img-size", type=int, default=224)
    p.add_argument("--val-split", type=float, default=0.2)
    p.add_argument("--num-workers", type=int, default=4)
    p.add_argument("--freeze-backbone", action="store_true",
                   help="train only the classifier head (fast, good for CPU)")
    p.add_argument("--no-pretrained", action="store_true",
                   help="train from scratch instead of ImageNet weights")
    p.add_argument("--out", default="runs/mobilenetv2_grape.pth")
    p.add_argument("--overwrite", action="store_true",
                   help="allow --out to replace an existing checkpoint")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    # The default --out is the deployed checkpoint, and a retrain that silently
    # replaced it is how the export and the golden vectors came to disagree
    # (DD-019). Replacing a checkpoint has to be asked for.
    if os.path.exists(args.out) and not args.overwrite:
        raise SystemExit(f"{args.out} exists - choose another --out, or pass --overwrite")

    set_seed(args.seed)
    device = pick_device()
    print(f"Device: {device}")

    train_loader, val_loader, classes = make_dataloaders(
        args.data, args.batch_size, args.img_size, args.val_split, args.num_workers, args.seed)
    print(f"Classes ({len(classes)}): {classes}")
    print(f"Train batches: {len(train_loader)} | Val batches: {len(val_loader)}")

    model = build_model(len(classes), pretrained=not args.no_pretrained).to(device)
    if args.freeze_backbone:
        set_backbone_trainable(model, False)
        print("Backbone frozen - training classifier head only.")

    criterion = nn.CrossEntropyLoss()
    params = [pp for pp in model.parameters() if pp.requires_grad]
    optimizer = torch.optim.SGD(params, lr=args.lr, momentum=0.9,
                                weight_decay=args.weight_decay, nesterov=True)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    scaler = torch.amp.GradScaler("cuda") if device == "cuda" else None

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    log_path = os.path.splitext(args.out)[0] + ".csv"
    provenance = {
        "data": os.path.basename(os.path.normpath(args.data)),
        "train_images": len(train_loader.dataset),
        "val_images": len(val_loader.dataset),
        "epochs": args.epochs, "batch_size": args.batch_size, "lr": args.lr,
        "weight_decay": args.weight_decay, "seed": args.seed,
        "freeze_backbone": args.freeze_backbone, "pretrained": not args.no_pretrained,
        "torch": torch.__version__,
    }
    best_acc, best_loss = 0.0, float("inf")
    with open(log_path, "w", newline="") as fh:
        log = csv.writer(fh)
        log.writerow(["epoch", "lr", "train_loss", "train_acc", "val_loss", "val_acc",
                      "seconds", "saved"])
        for epoch in range(1, args.epochs + 1):
            t0 = time.time()
            lr = scheduler.get_last_lr()[0]
            tr_loss, tr_acc = run_epoch(model, train_loader, device, criterion, optimizer, scaler)
            va_loss, va_acc = run_epoch(model, val_loader, device, criterion)
            scheduler.step()
            secs = time.time() - t0
            print(f"epoch {epoch:3d}/{args.epochs} | "
                  f"train loss {tr_loss:.3f} acc {tr_acc:.3f} | "
                  f"val loss {va_loss:.3f} acc {va_acc:.3f} | {secs:.0f}s")
            # accuracy first; on a tie (val accuracy saturates near 1.0) the
            # lower loss is the more confident, better-separated model
            saved = va_acc > best_acc or (va_acc == best_acc and va_loss < best_loss)
            if saved:
                best_acc, best_loss = va_acc, va_loss
                save_checkpoint(args.out, model, classes, args.img_size,
                                IMAGENET_MEAN, IMAGENET_STD, best_acc,
                                extra={**provenance, "best_epoch": epoch,
                                       "val_loss": va_loss})
                print(f"  saved new best -> {args.out} (val acc {best_acc:.3f}, "
                      f"loss {best_loss:.4f})")
            log.writerow([epoch, f"{lr:.6g}", f"{tr_loss:.5f}", f"{tr_acc:.5f}",
                          f"{va_loss:.5f}", f"{va_acc:.5f}", f"{secs:.1f}", int(saved)])
            fh.flush()

    print(f"\nBest val accuracy: {best_acc:.4f} (loss {best_loss:.4f}) - a selection "
          f"score, not a result; the result is evaluate.py --split test.")
    print(f"Checkpoint: {args.out}")
    print(f"Log: {log_path}")


if __name__ == "__main__":
    main()