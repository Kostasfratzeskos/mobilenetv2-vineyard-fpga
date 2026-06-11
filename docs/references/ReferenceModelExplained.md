### 2026-06-09

# Generally about MobileNetV2
- MobileNetV2 is a light weight pretrained model on ImageNet dataset. This is an ideal model for leave's diseases recognision because it already recognises patterns like edges and leaves from the ImageNet dataset. What I do here is that deploy transfer learning to this model with my own dataset (grape's leaves). By deploying this method I keep frozen all the layers (they have already trained weights) and change only the classifier head to what i really care (4 grape classes).

# Code Explanation
- mobilenetv2.py is torchvision's MobileNetV2, unchanged, with only the final classifier swapped. Basically the only thing that changed is this part of code:
    model.classifier = nn.Sequential(
        nn.Dropout(p=0.2),
        nn.Linear(1280, num_classes),   # num_classes = 4
    )
, where num_classes is auto-detected from my folders name, so it became 4 (black_rot, esca, healthy, leaf_blight).

- dataset.py takes the data and apply augmentation methods in order to avoid overfitting. More specifically what it does:
 RandomResizedCrop(224, scale=(0.6, 1.0)) --> random zoom/crop
 RandomHorizontalFlip --> flip the image
 ColorJitter(0.2, 0.2, 0.2) --> small brightness/contrast/saturation

- About training
    The script picks the device (CUDA → MPS → CPU), builds the model from ImageNet weights, runs the loop, and saves the best-validation checkpoint. 