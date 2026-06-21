import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

const _kModelAsset = 'assets/models/u2netp.onnx';

/// 电商平台尺寸预设
class PlatformSize {
  final String name;
  final int width;
  final int height;

  const PlatformSize(this.name, this.width, this.height);

  static const taobao = PlatformSize('淘宝主图', 800, 800);
  static const pinduoduo = PlatformSize('拼多多主图', 750, 750);
  static const jd = PlatformSize('京东主图', 800, 800);
  static const douyin = PlatformSize('抖音商品图', 900, 500);
  static const alibaba = PlatformSize('1688主图', 750, 750);
  static const xianyu = PlatformSize('闲鱼', 800, 800);

  static const all = [taobao, pinduoduo, jd, douyin, alibaba, xianyu];
}

/// 批量处理结果
class BatchResult {
  final String inputPath;
  final String? outputPath;
  final String? error;
  final bool success;

  const BatchResult({
    required this.inputPath,
    this.outputPath,
    this.error,
    required this.success,
  });
}

class U2NetService {
  final OnnxRuntime _ort = OnnxRuntime();
  OrtSession? _session;
  static const int inputSize = 320;

  Future<void> initialize() async {
    try {
      final sessionOptions = OrtSessionOptions(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
      );
      _session = await _ort.createSessionFromAsset(
        _kModelAsset,
        options: sessionOptions,
      );
      if (kDebugMode) {
        debugPrint('U2Net模型加载成功');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('模型加载失败: $e');
      }
      rethrow;
    }
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }

  /// 预处理 - 转换图像为模型输入张量
  static Float32List _preprocessImage(img.Image image) {
    final resized = img.copyResize(image, width: inputSize, height: inputSize);
    final input = Float32List(1 * 3 * inputSize * inputSize);
    int idx = 0;
    for (int c = 0; c < 3; c++) {
      for (int h = 0; h < inputSize; h++) {
        for (int w = 0; w < inputSize; w++) {
          final pixel = resized.getPixel(w, h);
          double value;
          if (c == 0) {
            value = pixel.r / 255.0;
          } else if (c == 1) {
            value = pixel.g / 255.0;
          } else {
            value = pixel.b / 255.0;
          }
          input[idx++] = value.toDouble();
        }
      }
    }
    return input;
  }

  /// 后处理 - 生成mask
  static img.Image _postprocessMask(List<double> output, int width, int height) {
    final mask = img.Image(width: inputSize, height: inputSize);
    double minVal = output[0];
    double maxVal = output[0];
    for (var val in output) {
      if (val < minVal) minVal = val;
      if (val > maxVal) maxVal = val;
    }
    final range = maxVal - minVal;
    for (int h = 0; h < inputSize; h++) {
      for (int w = 0; w < inputSize; w++) {
        final idx = h * inputSize + w;
        double normalized = range > 0 ? (output[idx] - minVal) / range : 0;
        final value = (normalized * 255).clamp(0, 255).toInt();
        mask.setPixelRgba(w, h, value, value, value, 255);
      }
    }
    return img.copyResize(mask, width: width, height: height);
  }

  /// 应用 mask 生成透明背景图像
  static img.Image _applyMask(img.Image image, img.Image mask) {
    final result = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 4,
    );
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final originalPixel = image.getPixel(x, y);
        final maskPixel = mask.getPixel(x, y);
        final alpha = maskPixel.r.toInt();
        final color = img.ColorRgba8(
          originalPixel.r.toInt(),
          originalPixel.g.toInt(),
          originalPixel.b.toInt(),
          alpha,
        );
        result.setPixel(x, y, color);
      }
    }
    return result;
  }

  /// 核心抠图 - 输入图像，输出透明背景RGBA图像
  Future<img.Image> removeBackground(img.Image image) async {
    if (_session == null) {
      throw Exception('模型未初始化，请先调用initialize()');
    }
    try {
      final originalWidth = image.width;
      final originalHeight = image.height;
      final inputData = _preprocessImage(image);
      final inputTensor = await OrtValue.fromList(
        inputData,
        [1, 3, inputSize, inputSize],
      );
      final inputName = _session!.inputNames.first;
      final outputs = await _session!.run({inputName: inputTensor});
      final outputName = _session!.outputNames.first;
      final outputTensor = outputs[outputName]!;
      final rawOutput = await outputTensor.asFlattenedList();
      final outputData = rawOutput.map((e) => (e as num).toDouble()).toList();
      final mask = _postprocessMask(outputData, originalWidth, originalHeight);
      final result = _applyMask(image, mask);
      await inputTensor.dispose();
      for (final tensor in outputs.values) {
        await tensor.dispose();
      }
      return result;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('背景移除失败: $e');
      }
      rethrow;
    }
  }

  /// 从文件路径抠图
  Future<img.Image> removeBackgroundFromFile(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw Exception('无法解码图像: $imagePath');
    }
    return removeBackground(image);
  }

  /// 白底填充 - 将透明区域替换为纯白背景 (#FFFFFF)
  static img.Image addWhiteBackground(img.Image rgbaImage) {
    final result = img.Image(
      width: rgbaImage.width,
      height: rgbaImage.height,
      numChannels: 3,
    );
    for (int y = 0; y < rgbaImage.height; y++) {
      for (int x = 0; x < rgbaImage.width; x++) {
        final pixel = rgbaImage.getPixel(x, y);
        final alpha = pixel.a.toInt();
        if (alpha == 0) {
          result.setPixelRgba(x, y, 255, 255, 255, 255);
        } else if (alpha < 255) {
          final blend = alpha / 255.0;
          final r = (pixel.r.toInt() * blend + 255 * (1 - blend)).round();
          final g = (pixel.g.toInt() * blend + 255 * (1 - blend)).round();
          final b = (pixel.b.toInt() * blend + 255 * (1 - blend)).round();
          result.setPixelRgba(x, y, r, g, b, 255);
        } else {
          result.setPixelRgba(
            x, y, pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt(), 255);
        }
      }
    }
    return result;
  }

  /// 平台尺寸适配 - 居中裁剪/填充
  /// 保持主体居中，按目标尺寸等比缩放后居中裁剪
  static img.Image resizeForPlatform(img.Image image, PlatformSize platform) {
    final targetW = platform.width;
    final targetH = platform.height;

    // 先创建纯白画布
    final canvas = img.Image(
      width: targetW,
      height: targetH,
      numChannels: 3,
    );
    // 填充白色
    for (int y = 0; y < targetH; y++) {
      for (int x = 0; x < targetW; x++) {
        canvas.setPixelRgba(x, y, 255, 255, 255, 255);
      }
    }

    // 计算缩放比例，使图像完整显示在目标画布内
    final scale = (targetW / image.width) < (targetH / image.height)
        ? targetW / image.width
        : targetH / image.height;

    final scaledW = (image.width * scale).round();
    final scaledH = (image.height * scale).round();

    // 居中放置
    final offsetX = (targetW - scaledW) ~/ 2;
    final offsetY = (targetH - scaledH) ~/ 2;

    final resized = img.copyResize(image, width: scaledW, height: scaledH);
    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);

    return canvas;
  }

  /// 完整处理流程：抠图 → 白底填充 → 尺寸适配
  Future<img.Image> processFullPipeline(
    img.Image input, {
    bool whiteBackground = true,
    PlatformSize? platformSize,
  }) async {
    var result = await removeBackground(input);
    if (whiteBackground) {
      result = addWhiteBackground(result);
    }
    if (platformSize != null) {
      result = resizeForPlatform(result as img.Image, platformSize);
    }
    return result;
  }

  /// 批量处理
  Future<List<BatchResult>> batchProcess(
    List<String> imagePaths, {
    bool whiteBackground = true,
    PlatformSize? platformSize,
    void Function(int current, int total)? onProgress,
  }) async {
    final results = <BatchResult>[];
    final outputDir = await _getBatchOutputDir();

    for (int i = 0; i < imagePaths.length; i++) {
      onProgress?.call(i + 1, imagePaths.length);
      try {
        final image = await removeBackgroundFromFile(imagePaths[i]);
        var processed = whiteBackground ? addWhiteBackground(image) : image;
        if (platformSize != null) {
          processed = resizeForPlatform(processed, platformSize);
        }

        final inputName = imagePaths[i].split('/').last.split('.').first;
        final ext = whiteBackground ? 'jpg' : 'png';
        final outputPath =
            '${outputDir.path}/${inputName}_${platformSize?.name ?? 'processed'}.$ext';

        final file = File(outputPath);
        final encoded = whiteBackground
            ? img.encodeJpg(processed)
            : img.encodePng(processed);
        await file.writeAsBytes(encoded);

        results.add(BatchResult(
          inputPath: imagePaths[i],
          outputPath: outputPath,
          success: true,
        ));
      } catch (e) {
        results.add(BatchResult(
          inputPath: imagePaths[i],
          success: false,
          error: e.toString(),
        ));
      }
    }
    return results;
  }

  Future<Directory> _getBatchOutputDir() async {
    final baseDir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final dir = Directory('${baseDir.path}/batch_$timestamp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 保存图像
  Future<String> saveImage(img.Image image, String filename) async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/$filename';
    final file = File(path);
    await file.writeAsBytes(img.encodePng(image));
    return path;
  }
}
