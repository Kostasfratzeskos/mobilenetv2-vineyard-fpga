"""Classify a single leaf image with a trained checkpoint.

Run from inside software/:
    python predict.py --ckpt runs/mobilenetv2_grape.pth --image leaf.jpg
"""
from __future__ import annotations

import argparse
import os
import sys

import torch
import torch.nn.functional as F
from PIL import Image
from torchvision import transforms

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from model.mobilenetv2 import load_checkpoint  # noqa: E402
from train.dataset import IMAGENET_MEAN, IMAGENET_STD  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ckpt", required=True)
    p.add_argument("--image", required=True)
    p.add_argument("--topk", type=int, default=3)
    args = p.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model, ckpt = load_checkpoint(args.ckpt, map_location=device)
    model.to(device).eval()
    classes = ckpt["classes"]
    img_size = ckpt.get("img_size", 224)

    resize = int(round(img_size * 256 / 224))
    tf = transforms.Compose([
        transforms.Resize(resize),
        transforms.CenterCrop(img_size),
        transforms.ToTensor(),
        transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])
    img = Image.open(args.image).convert("RGB")
    x = tf(img).unsqueeze(0).to(device)
    with torch.no_grad():
        probs = F.softmax(model(x), dim=1)[0]

    k = min(args.topk, len(classes))
    top = torch.topk(probs, k)
    print(f"Prediction for {os.path.basename(args.image)}:")
    for prob, idx in zip(top.values.tolist(), top.indices.tolist()):
        print(f"  {classes[idx]:<20s} {prob * 100:5.1f}%")


if __name__ == "__main__":
    main()
