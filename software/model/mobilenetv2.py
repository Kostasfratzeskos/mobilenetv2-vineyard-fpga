"""MobileNetV2 reference model for vineyard disease classification.

Loads an ImageNet-pretrained MobileNetV2 and replaces the 1000-class head with a
head sized to your dataset. This is the float "source of truth" for the thesis;
the int8 quantized version and the bit-exact golden vectors are derived from the
weights trained here.
"""
from __future__ import annotations

import torch
import torch.nn as nn

try:
    from torchvision.models import mobilenet_v2, MobileNet_V2_Weights
    _HAS_WEIGHTS_ENUM = True
except ImportError:  # older torchvision
    from torchvision.models import mobilenet_v2
    _HAS_WEIGHTS_ENUM = False


def build_model(num_classes: int, pretrained: bool = True, dropout: float = 0.2) -> nn.Module:
    """Return a MobileNetV2 with its classifier resized to `num_classes`."""
    if pretrained and _HAS_WEIGHTS_ENUM:
        model = mobilenet_v2(weights=MobileNet_V2_Weights.IMAGENET1K_V1)
    elif pretrained:
        model = mobilenet_v2(pretrained=True)
    elif _HAS_WEIGHTS_ENUM:
        model = mobilenet_v2(weights=None)
    else:
        model = mobilenet_v2(pretrained=False)

    in_features = model.last_channel  # 1280
    model.classifier = nn.Sequential(
        nn.Dropout(p=dropout),
        nn.Linear(in_features, num_classes),
    )
    return model


def set_backbone_trainable(model: nn.Module, trainable: bool) -> None:
    """Freeze/unfreeze the feature extractor; the classifier head stays trainable."""
    for p in model.features.parameters():
        p.requires_grad = trainable


def save_checkpoint(path, model, classes, img_size, mean, std, best_acc, extra=None):
    ckpt = {
        "arch": "mobilenet_v2",
        "state_dict": model.state_dict(),
        "classes": list(classes),
        "num_classes": len(classes),
        "img_size": int(img_size),
        "norm_mean": list(mean),
        "norm_std": list(std),
        "best_acc": float(best_acc),
    }
    if extra:
        ckpt.update(extra)
    torch.save(ckpt, path)


def load_checkpoint(path, map_location="cpu"):
    """Load a checkpoint and rebuild the model with the right head. Returns (model, ckpt)."""
    try:
        ckpt = torch.load(path, map_location=map_location, weights_only=False)
    except TypeError:  # older torch has no weights_only kwarg
        ckpt = torch.load(path, map_location=map_location)
    model = build_model(ckpt["num_classes"], pretrained=False)
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    return model, ckpt
