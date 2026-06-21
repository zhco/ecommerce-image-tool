import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image/image.dart' as img;
import '../services/u2net_service.dart';

class PlatformSize {
  final String name;
  final int width;
  final int height;
  const PlatformSize(this.name, this.width, this.height);
  
  static const all = [
    PlatformSize('淘宝主图', 800, 800),
    PlatformSize('淘宝3:4', 750, 1000),
    PlatformSize('拼多多主图', 750, 750),
    PlatformSize('拼多多3:4', 600, 800),
    PlatformSize('京东主图', 800, 800),
    PlatformSize('抖音商品', 900, 500),
    PlatformSize('1688主图', 750, 750),
    PlatformSize('闲鱼', 800, 800),
    PlatformSize('小红书', 1080, 1440),
  ];
}

class BatchResult {
  final bool success;
  final String inputPath;
  final String? outputPath;
  final String? error;
  const BatchResult({required this.success, required this.inputPath, this.outputPath, this.error});
}

class CheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const squareSize = 10.0;
    final paint1 = Paint()..color = Colors.grey[200]!;
    final paint2 = Paint()..color = Colors.white;
    for (double y = 0; y < size.height; y += squareSize) {
      for (double x = 0; x < size.width; x += squareSize) {
        final isEven = ((x ~/ squareSize) + (y ~/ squareSize)) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(x, y, squareSize, squareSize),
          isEven ? paint1 : paint2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ImageMattingPage extends StatefulWidget {
  const ImageMattingPage({super.key});

  @override
  State<ImageMattingPage> createState() => _ImageMattingPageState();
}

class _ImageMattingPageState extends State<ImageMattingPage> {
  final U2NetService _u2netService = U2NetService();
  final ImagePicker _picker = ImagePicker();

  bool _isProcessing = false;

  bool _isBatchMode = false;
  bool _whiteBackground = true;
  PlatformSize? _selectedPlatform;

  String? _originalImagePath;
  String? _processedImagePath;

  List<String> _batchImagePaths = [];
  List<BatchResult> _batchResults = [];
  int _batchProgress = 0;

  // ─── 单张模式 ───

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image != null) {
        setState(() {
          _originalImagePath = image.path;
          _processedImagePath = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    }
  }

  Future<void> _processSingle() async {
    if (_originalImagePath == null) return;
    setState(() => _isProcessing = true);

    try {
      final bytes = await File(_originalImagePath!).readAsBytes();
      var image = img.decodeImage(bytes);
      if (image == null) throw Exception('无法解码图片');

      // 抠图
      final noBg = await _u2netService.removeBackground(image);
      image = noBg ?? image;

      // 白底填充
      if (_whiteBackground) {
        image = _u2netService.addWhiteBackground(image);
      }

      // 尺寸适配
      if (_selectedPlatform != null) {
        image = _u2netService.resizeForPlatform(
          image, _selectedPlatform!.width, _selectedPlatform!.height);
      }

      // 保存
      final ext = _whiteBackground ? 'jpg' : 'png';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dir = Directory('/storage/emulated/0/Pictures');
      if (!await dir.exists()) await dir.create(recursive: true);
      final savedPath = '${dir.path}/processed_$timestamp.$ext';
      final outBytes = _whiteBackground
          ? img.encodeJpg(image, quality: 95)
          : img.encodePng(image);
      await File(savedPath).writeAsBytes(outBytes);

      setState(() {
        _processedImagePath = savedPath;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('处理失败: $e')),
        );
      }
    }
  }

  // ─── 批量模式 ───

  Future<void> _pickBatchImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _batchImagePaths = result.files
              .where((f) => f.path != null)
              .map((f) => f.path!)
              .toList();
          _batchResults = [];
          _batchProgress = 0;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    }
  }

  Future<void> _processBatch() async {
    if (_batchImagePaths.isEmpty) return;
    setState(() {
      _isProcessing = true;
      _batchProgress = 0;
      _batchResults = [];
    });

    final total = _batchImagePaths.length;
    for (int i = 0; i < total; i++) {
      try {
        final path = _batchImagePaths[i];
        final bytes = await File(path).readAsBytes();
        var image = img.decodeImage(bytes);
        if (image == null) throw Exception('解码失败');

        final noBg = await _u2netService.removeBackground(image);
        image = noBg ?? image;

        if (_whiteBackground) {
          image = _u2netService.addWhiteBackground(image);
        }

        if (_selectedPlatform != null) {
          image = _u2netService.resizeForPlatform(
            image, _selectedPlatform!.width, _selectedPlatform!.height);
        }

        final ext = _whiteBackground ? 'jpg' : 'png';
        final name = path.split('/').last.split('.').first;
        final dir = Directory('/storage/emulated/0/Pictures');
        if (!await dir.exists()) await dir.create(recursive: true);
        final outPath = '${dir.path}/${name}_processed.$ext';
        final outBytes = _whiteBackground
            ? img.encodeJpg(image, quality: 95)
            : img.encodePng(image);
        await File(outPath).writeAsBytes(outBytes);

        _batchResults.add(BatchResult(success: true, inputPath: path, outputPath: outPath));
      } catch (e) {
        _batchResults.add(BatchResult(
          success: false,
          inputPath: _batchImagePaths[i],
          error: e.toString(),
        ));
      }
      setState(() => _batchProgress = i + 1);
    }

    setState(() => _isProcessing = false);

    if (mounted) {
      final successCount = _batchResults.where((r) => r.success).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('批量处理完成：$successCount/$total 张成功')),
      );
    }
  }

  void _shareImage(String path) {
    Share.shareXFiles([XFile(path)], text: '电商图片处理结果');
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('电商图片处理'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_isBatchMode && _batchImagePaths.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: () => setState(() {
                _batchImagePaths = [];
                _batchResults = [];
              }),
              tooltip: '清除列表',
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildModeToggle(),
            const SizedBox(height: 12),
            _buildOptionsCard(),
            const SizedBox(height: 12),
            if (_isBatchMode) _buildBatchSection() else _buildSingleSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('单张处理'), icon: Icon(Icons.photo)),
        ButtonSegment(value: true, label: Text('批量处理'), icon: Icon(Icons.collections)),
      ],
      selected: {_isBatchMode},
      onSelectionChanged: (v) => setState(() {
        _isBatchMode = v.first;
        if (_isBatchMode) {
          _originalImagePath = null;
          _processedImagePath = null;
        }
      }),
    );
  }

  Widget _buildOptionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('处理选项', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('自动生成白底图'),
              subtitle: const Text('抠图后填充纯白背景 (#FFFFFF)'),
              value: _whiteBackground,
              onChanged: (v) => setState(() => _whiteBackground = v),
              dense: true,
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 4),
              child: Text('平台尺寸适配', style: TextStyle(fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('原始尺寸'),
                    selected: _selectedPlatform == null,
                    onSelected: (_) => setState(() => _selectedPlatform = null),
                  ),
                  ...PlatformSize.all.map((p) => ChoiceChip(
                        label: Text('${p.name} ${p.width}×${p.height}'),
                        selected: _selectedPlatform?.name == p.name,
                        onSelected: (_) =>
                            setState(() => _selectedPlatform = p),
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: const Text('从相册选择'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt),
                label: const Text('拍照'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_originalImagePath != null) ...[
          _buildImagePreview('原始图片', _originalImagePath!, showChecker: false),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _processSingle,
            icon: _isProcessing
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.auto_fix_high),
            label: Text(_isProcessing ? '处理中...' : '开始处理'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
        if (_processedImagePath != null) ...[
          const SizedBox(height: 16),
          _buildImagePreview('处理结果', _processedImagePath!, showChecker: true),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.share, size: 18),
                label: const Text('分享'),
                onPressed: () => _shareImage(_processedImagePath!),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildBatchSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _pickBatchImages,
          icon: const Icon(Icons.add_photo_alternate),
          label: Text(
            _batchImagePaths.isEmpty
                ? '选择多张图片'
                : '已选 ${_batchImagePaths.length} 张，点击重新选择',
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (_batchImagePaths.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _batchImagePaths.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(_batchImagePaths[i]),
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_isProcessing) ...[
            LinearProgressIndicator(
              value: _batchImagePaths.isNotEmpty
                  ? _batchProgress / _batchImagePaths.length
                  : 0,
            ),
            const SizedBox(height: 4),
            Text(
              '处理中 $_batchProgress / ${_batchImagePaths.length}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
          if (!_isProcessing)
            ElevatedButton.icon(
              onPressed: _processBatch,
              icon: const Icon(Icons.batch_prediction),
              label: Text('批量处理 ${_batchImagePaths.length} 张'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
        ],
        if (_batchResults.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '处理结果 (${_batchResults.where((r) => r.success).length}/${_batchResults.length} 成功)',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          ..._batchResults.map((r) => Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    r.success ? Icons.check_circle : Icons.error,
                    color: r.success ? Colors.green : Colors.red,
                    size: 22,
                  ),
                  title: Text(
                    r.inputPath.split('/').last,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: r.success
                      ? Text('已保存', style: TextStyle(fontSize: 11, color: Colors.grey[600]))
                      : Text(r.error ?? '错误', style: const TextStyle(fontSize: 11, color: Colors.red)),
                  trailing: r.success
                      ? IconButton(
                          icon: const Icon(Icons.share, size: 18),
                          onPressed: () => _shareImage(r.outputPath!),
                        )
                      : null,
                ),
              )),
        ],
      ],
    );
  }

  Widget _buildImagePreview(String label, String path,
      {bool showChecker = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey[300]!),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                if (showChecker)
                  Positioned.fill(
                    child: CustomPaint(painter: CheckerboardPainter()),
                  ),
                Image.file(File(path), fit: BoxFit.contain),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
