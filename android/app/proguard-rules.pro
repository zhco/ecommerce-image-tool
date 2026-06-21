# ONNX Runtime - 防止 R8 混淆导致 JNI 崩溃
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# Flutter
-keep class io.flutter.** { *; }
