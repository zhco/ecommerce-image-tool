import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class U2NetService {
  bool _initialized = true;
  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    _initialized = true;
  }

  /// 基于边缘检测+泛洪填充的背景移除
  /// 无需 AI 模型，纯 Dart 实现，零闪退
  Future<img.Image?> removeBackground(img.Image src) async {
    if (!_initialized) return null;

    final image = img.Image.from(src);
    final width = image.width;
    final height = image.height;

    // 1. 灰度化
    final gray = img.grayscale(image);

    // 2. 边缘检测 (Sobel)
    final edges = _sobelEdgeDetect(gray);

    // 3. 从四边泛洪填充标记背景
    final bgMask = _floodFillBackground(edges, width, height);

    // 4. 创建透明背景图
    return _applyMask(image, bgMask);
  }

  /// Sobel 边缘检测
  Uint8List _sobelEdgeDetect(img.Image gray) {
    final w = gray.width;
    final h = gray.height;
    final result = Uint8List(w * h);

    // Sobel kernels
    const gx = [-1, 0, 1, -2, 0, 2, -1, 0, 1];
    const gy = [-1, -2, -1, 0, 0, 0, 1, 2, 1];

    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        int sx = 0, sy = 0;
        int ki = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final p = gray.getPixel(x + dx, y + dy);
            final lum = img.getLuminance(p);
            sx += (lum * gx[ki]).toInt();
            sy += (lum * gy[ki]).toInt();
            ki++;
          }
        }
        final mag = (sqrt(sx * sx + sy * sy)).toInt().clamp(0, 255);
        result[y * w + x] = mag;
      }
    }
    return result;
  }

  /// 从四边泛洪标记背景区域
  Uint8List _floodFillBackground(Uint8List edges, int w, int h) {
    final mask = Uint8List(w * h); // 0=背景, 1=前景
    final edgeThreshold = 30;

    for (int i = 0; i < w * h; i++) {
      mask[i] = 1; // 默认前景
    }

    // 从边缘向内泛洪
    final queue = <int>[];
    final visited = Uint8List(w * h);

    // 四边加入队列
    for (int x = 0; x < w; x++) {
      if (edges[x] < edgeThreshold) {
        queue.add(x);
        visited[x] = 1;
      }
      if (edges[(h - 1) * w + x] < edgeThreshold) {
        queue.add((h - 1) * w + x);
        visited[(h - 1) * w + x] = 1;
      }
    }
    for (int y = 1; y < h - 1; y++) {
      if (edges[y * w] < edgeThreshold) {
        queue.add(y * w);
        visited[y * w] = 1;
      }
      if (edges[y * w + w - 1] < edgeThreshold) {
        queue.add(y * w + w - 1);
        visited[y * w + w - 1] = 1;
      }
    }

    // BFS
    int qi = 0;
    while (qi < queue.length) {
      final idx = queue[qi++];
      mask[idx] = 0; // 标记为背景

      final x = idx % w;
      final y = idx ~/ w;

      // 8方向邻居
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
          final nidx = ny * w + nx;
          if (visited[nidx] == 1) continue;
          if (edges[nidx] >= edgeThreshold) continue;
          visited[nidx] = 1;
          queue.add(nidx);
        }
      }
    }

    return mask;
  }

  /// 应用蒙版，背景变透明
  img.Image _applyMask(img.Image src, Uint8List mask) {
    final result = img.Image(width: src.width, height: src.height);
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        if (mask[y * src.width + x] == 1) {
          result.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 255);
        } else {
          // 边缘区域保持半透明过渡
          final edgeDist = _getEdgeDist(mask, x, y, src.width, src.height);
          final alpha = (edgeDist * 255).toInt().clamp(0, 255);
          result.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), alpha);
        }
      }
    }
    return result;
  }

  int _getEdgeDist(Uint8List mask, int x, int y, int w, int h) {
    // 简单羽化：边缘3像素内渐变
    for (int d = 1; d <= 3; d++) {
      for (int dy = -d; dy <= d; dy++) {
        for (int dx = -d; dx <= d; dx++) {
          final nx = (x + dx).clamp(0, w - 1);
          final ny = (y + dy).clamp(0, h - 1);
          if (mask[ny * w + nx] == 1) return d ~/ 3;
        }
      }
    }
    return 0;
  }

  /// 白底填充
  img.Image addWhiteBackground(img.Image src) {
    final result = img.Image(width: src.width, height: src.height);
    img.fill(result, color: img.ColorRgba8(255, 255, 255, 255));

    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        if (p.a > 0) {
          result.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 255);
        }
      }
    }
    return result;
  }

  /// 适配平台尺寸
  img.Image resizeForPlatform(img.Image src, int targetW, int targetH) {
    final iw = src.width;
    final ih = src.height;
    final ratio = min(targetW / iw, targetH / ih);
    final nw = (iw * ratio).round();
    final nh = (ih * ratio).round();

    final resized = img.copyResize(src, width: nw, height: nh,
        interpolation: img.Interpolation.linear);

    final canvas = img.Image(width: targetW, height: targetH);
    img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));

    final ox = (targetW - nw) ~/ 2;
    final oy = (targetH - nh) ~/ 2;
    img.compositeImage(canvas, resized, dstX: ox, dstY: oy);

    return canvas;
  }

  /// 批量处理
  Future<List<String>> batchProcess(List<String> paths, String outputDir,
      {int? targetW, int? targetH}) async {
    final results = <String>[];

    for (final path in paths) {
      try {
        final bytes = await File(path).readAsBytes();
        var image = img.decodeImage(bytes);
        if (image == null) continue;

        // 抠图
        final noBg = await removeBackground(image);
        if (noBg != null) image = noBg;

        // 白底
        image = addWhiteBackground(image);

        // 尺寸适配
        if (targetW != null && targetH != null) {
          image = resizeForPlatform(image, targetW, targetH);
        }

        // 保存
        final name = path.split('/').last.split('.').first;
        final outPath = '$outputDir/${name}_processed.png';
        final outBytes = img.encodePng(image);
        await File(outPath).writeAsBytes(outBytes);
        results.add(outPath);
      } catch (e) {
        results.add('ERROR: $path - $e');
      }
    }
    return results;
  }
}
