# ONNX Runtime - 防止 R8 混淆导致 JNI 崩溃
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# Google Play Core - Flutter deferred components
-dontwarn com.google.android.play.core.**

# Flutter
-keep class io.flutter.** { *; }
