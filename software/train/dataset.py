"""Data loading for the grape-disease dataset.

Expects an ImageFolder layout (one subfolder per class):

    data/
      black_rot/      img001.jpg ...
      esca/           ...
      leaf_blight/    ...
      healthy/        ...

Or a pre-split layout:

    data/
      train/   <class folders>
      val/     <class folders>

Classes are detected automatically from the folder names (sorted).

NOTE: the normalization below (ImageNet mean/std) becomes part of your fixed-point
scheme later. The PS preprocessing on the FPGA must apply the *same* resize +
normalize + quantize before feeding the accelerator, or the hardware output won't
match the software golden vectors.
"""
from __future__ import annotations

import os

import torch
from torch.utils.data import DataLoader, Subset
from torchvision import datasets, transforms

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


def _train_tf(img_size):
    return transforms.Compose([
        transforms.RandomResizedCrop(img_size, scale=(0.6, 1.0)),
        transforms.RandomHorizontalFlip(),
        transforms.ColorJitter(0.2, 0.2, 0.2),
        transforms.ToTensor(),
        transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])


def _eval_tf(img_size):
    resize = int(round(img_size * 256 / 224))
    return transforms.Compose([
        transforms.Resize(resize),
        transforms.CenterCrop(img_size),
        transforms.ToTensor(),
        transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])


def make_dataloaders(data_dir, batch_size=32, img_size=224, val_split=0.2,
                     num_workers=4, seed=42):
    """Return (train_loader, val_loader, classes)."""
    train_dir = os.path.join(data_dir, "train")
    val_dir = os.path.join(data_dir, "val")

    if os.path.isdir(train_dir) and os.path.isdir(val_dir):
        train_ds = datasets.ImageFolder(train_dir, _train_tf(img_size))
        val_ds = datasets.ImageFolder(val_dir, _eval_tf(img_size))
        classes = train_ds.classes
    else:
        # single folder -> split by index, with the correct transform per split
        base_train = datasets.ImageFolder(data_dir, _train_tf(img_size))
        base_val = datasets.ImageFolder(data_dir, _eval_tf(img_size))
        classes = base_train.classes
        n = len(base_train)
        n_val = max(1, int(round(n * val_split)))
        g = torch.Generator().manual_seed(seed)
        perm = torch.randperm(n, generator=g).tolist()
        val_idx, train_idx = perm[:n_val], perm[n_val:]
        train_ds = Subset(base_train, train_idx)
        val_ds = Subset(base_val, val_idx)

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True,
                              num_workers=num_workers, pin_memory=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False,
                            num_workers=num_workers, pin_memory=True)
    return train_loader, val_loader, classes


def make_eval_loader(data_dir, batch_size=32, img_size=224, num_workers=4):
    """Return (loader, classes) over an eval set (uses data/val if present, else all of data)."""
    eval_dir = os.path.join(data_dir, "val")
    root = eval_dir if os.path.isdir(eval_dir) else data_dir
    ds = datasets.ImageFolder(root, _eval_tf(img_size))
    loader = DataLoader(ds, batch_size=batch_size, shuffle=False,
                        num_workers=num_workers, pin_memory=True)
    return loader, ds.classes
