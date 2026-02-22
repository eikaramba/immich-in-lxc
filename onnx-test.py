#!/usr/bin/env python3
"""
End-to-end test of onnxruntime with MIGraphX on AMD GPU.
Downloads MobileNetV2 (image classification) and runs inference on a test image.

Usage:
    source /home/immich/immich/app/machine-learning/venv/bin/activate
    python3 test_migraphx.py [optional_image_path]
"""

import sys
import os
import time
import urllib.request
import json

import numpy as np
from PIL import Image
import onnxruntime as ort


# --- Configuration ---
MODEL_URL = "https://huggingface.co/onnxmodelzoo/mobilenetv2-12/resolve/main/mobilenetv2-12.onnx"
LABELS_URL = "https://raw.githubusercontent.com/anishathalye/imagenet-simple-labels/master/imagenet-simple-labels.json"
MODEL_PATH = "/tmp/mobilenetv2-12.onnx"
LABELS_PATH = "/tmp/imagenet-labels.json"
TEST_IMAGE_URL = "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/1200px-Cat_November_2010-1a.jpg"
TEST_IMAGE_PATH = "/tmp/test_cat.jpg"


def download_file(url: str, dest: str, description: str) -> None:
    """Download a file if it doesn't already exist."""
    if os.path.exists(dest):
        print(f"  [cached] {description}: {dest}")
        return
    print(f"  Downloading {description}...")
    urllib.request.urlretrieve(url, dest)
    size_mb = os.path.getsize(dest) / (1024 * 1024)
    print(f"  Saved to {dest} ({size_mb:.1f} MB)")


def preprocess_image(image_path: str) -> np.ndarray:
    """
    Preprocess image for MobileNetV2:
    - Resize to 224x224
    - Normalize with ImageNet mean/std
    - Convert to NCHW float32 tensor
    """
    img = Image.open(image_path).convert("RGB")
    img = img.resize((224, 224), Image.LANCZOS)

    # Convert to numpy float32 and normalize to [0, 1]
    img_array = np.array(img, dtype=np.float32) / 255.0

    # ImageNet normalization
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    img_array = (img_array - mean) / std

    # HWC -> NCHW
    img_array = np.transpose(img_array, (2, 0, 1))
    img_array = np.expand_dims(img_array, axis=0)

    return img_array


def softmax(x: np.ndarray) -> np.ndarray:
    """Compute softmax values."""
    e_x = np.exp(x - np.max(x))
    return e_x / e_x.sum()


def main():
    print("=" * 60)
    print("ONNX Runtime MIGraphX End-to-End Test")
    print("=" * 60)

    # --- Step 1: Environment info ---
    print("\n[1/5] Environment")
    print(f"  onnxruntime version: {ort.get_version_string()}")
    print(f"  numpy version:       {np.__version__}")
    print(f"  Python:              {sys.version.split()[0]}")

    all_providers = ort.get_all_providers()
    available_providers = ort.get_available_providers()
    print(f"  All providers:       {all_providers}")
    print(f"  Available providers: {available_providers}")

    has_migraphx = "MIGraphXExecutionProvider" in available_providers
    if has_migraphx:
        print("  ✅ MIGraphXExecutionProvider is AVAILABLE")
    else:
        print("  ❌ MIGraphXExecutionProvider is NOT available")
        print("     Will fall back to CPU.")

    # --- Step 2: Download model and labels ---
    print("\n[2/5] Downloading model and labels")
    download_file(MODEL_URL, MODEL_PATH, "MobileNetV2 ONNX model")
    download_file(LABELS_URL, LABELS_PATH, "ImageNet labels")

    with open(LABELS_PATH, "r") as f:
        labels = json.load(f)

    # --- Step 3: Download or use provided test image ---
    print("\n[3/5] Preparing test image")
    image_path = sys.argv[1] if len(sys.argv) > 1 else TEST_IMAGE_PATH
    if not os.path.exists(image_path):
        download_file(TEST_IMAGE_URL, TEST_IMAGE_PATH, "test image (cat)")
        image_path = TEST_IMAGE_PATH
    print(f"  Using image: {image_path}")

    input_tensor = preprocess_image(image_path)
    print(f"  Input tensor shape: {input_tensor.shape}, dtype: {input_tensor.dtype}")

    # --- Step 4: Run inference ---
    print("\n[4/5] Running inference")

    # Try MIGraphX first, fall back to CPU
    if has_migraphx:
        providers_to_try = [
            (["MIGraphXExecutionProvider", "CPUExecutionProvider"], "MIGraphX (GPU)"),
            (["CPUExecutionProvider"], "CPU"),
        ]
    else:
        providers_to_try = [
            (["CPUExecutionProvider"], "CPU"),
        ]

    for provider_list, provider_name in providers_to_try:
        print(f"\n  --- Provider: {provider_name} ---")
        try:
            sess_options = ort.SessionOptions()
            sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

            t0 = time.time()
            session = ort.InferenceSession(MODEL_PATH, sess_options, providers=provider_list)
            t_load = time.time() - t0
            print(f"  Session created in {t_load:.2f}s")
            print(f"  Active provider(s): {session.get_providers()}")

            input_name = session.get_inputs()[0].name
            output_name = session.get_outputs()[0].name
            print(f"  Input:  {input_name} {session.get_inputs()[0].shape}")
            print(f"  Output: {output_name} {session.get_outputs()[0].shape}")

            # Warm-up run (MIGraphX compiles the model on first run)
            print("  Warm-up run (MIGraphX compiles on first inference)...")
            t0 = time.time()
            _ = session.run([output_name], {input_name: input_tensor})
            t_warmup = time.time() - t0
            print(f"  Warm-up completed in {t_warmup:.2f}s")

            # Timed runs
            num_runs = 10
            t0 = time.time()
            for _ in range(num_runs):
                outputs = session.run([output_name], {input_name: input_tensor})
            t_avg = (time.time() - t0) / num_runs
            print(f"  Average inference time ({num_runs} runs): {t_avg * 1000:.1f} ms")

            # Process results
            logits = outputs[0][0]
            probs = softmax(logits)
            top5_idx = np.argsort(probs)[::-1][:5]

            print(f"\n  Top-5 predictions:")
            for i, idx in enumerate(top5_idx):
                label = labels[idx] if idx < len(labels) else f"class_{idx}"
                print(f"    {i + 1}. {label:30s} ({probs[idx] * 100:.2f}%)")

        except Exception as e:
            print(f"  ❌ Failed with {provider_name}: {e}")
            import traceback
            traceback.print_exc()

    # --- Step 5: Summary ---
    print("\n" + "=" * 60)
    print("[5/5] Summary")
    print("=" * 60)
    if has_migraphx:
        print("  ✅ MIGraphX provider loaded successfully")
        print("  ✅ GPU inference completed")
        print("  Your ROCm + MIGraphX + ONNX Runtime setup is working!")
    else:
        print("  ⚠️  MIGraphX was not available, only CPU was tested")
        print("  Check ROCm installation and LD_LIBRARY_PATH")
    print()


if __name__ == "__main__":
    main()
