import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image/image.dart' as img;
import '../services/u2net_service.dart';

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

  bool _isInitialized = false;
  bool _initFailed = false;
  bool _isProcessing = false;

  // 模式切换：single / batch
  bool _isBatchMode = false;

  // 功能开关
  bool _whiteBackground = true;
  PlatformSize? _selectedPlatform;

  // 单张模式
  String? _originalImagePath;
  String? _processedImagePath;

  // 批量模式
  List<String> _batchImagePaths = [];
  List<BatchResult> _batchResults = [];
  int _batchProgress = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeModel());
  }

  Future<void> _initializeModel() async {
    try {
      await _u2netService.initialize();
      setState(() => _isInitialized = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI模型加载成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('模型加载失败: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _u2netService.dispose();
    super.dispose();
  }

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
    if (_originalImagePath == null || !_isInitialized) return;
    setState(() => _isProcessing = true);

    try {
      final bytes = await File(_originalImagePath!).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) throw Exception('无法解码图片');

      final result = await _u2netService.processFullPipeline(
        image,
        whiteBackground: _whiteBackground,
        platformSize: _selectedPlatform,
      );

      final ext = _whiteBackground ? 'jpg' : 'png';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final savedPath =
          await _u2netService.saveImage(result, 'single_$timestamp.$ext');

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
    if (_batchImagePaths.isEmpty || !_isInitialized) return;
    setState(() {
      _isProcessing = true;
      _batchProgress = 0;
      _batchResults = [];
    });

    final results = await _u2netService.batchProcess(
      _batchImagePaths,
      whiteBackground: _whiteBackground,
      platformSize: _selectedPlatform,
      onProgress: (current, total) {
        setState(() => _batchProgress = current);
      },
    );

    setState(() {
      _isProcessing = false;
      _batchResults = results;
    });

    if (mounted) {
      final successCount = results.where((r) => r.success).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '批量处理完成：$successCount/${results.length} 张成功'),
        ),
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
            _buildStatusCard(),
            const SizedBox(height: 12),
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

  Widget _buildStatusCard() {
    final icon = _isInitialized
        ? Icons.check_circle
        : _initFailed
            ? Icons.error
            : Icons.pending;
    final color = _isInitialized
        ? Colors.green
        : _initFailed
            ? Colors.red
            : Colors.orange;
    final text = _isInitialized
        ? 'AI模型就绪 (U2-Net)'
        : _initFailed
            ? '模型加载失败，请重试'
            : '模型加载中...';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontSize: 14)),
            if (_initFailed) ...[
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() => _initFailed = false);
                  _initializeModel();
                },
                child: const Text('重试'),
              ),
            ],
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

  // ─── 单张模式UI ───

  Widget _buildSingleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isInitialized
                    ? () => _pickImage(ImageSource.gallery)
                    : null,
                icon: const Icon(Icons.photo_library),
                label: const Text('从相册选择'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isInitialized
                    ? () => _pickImage(ImageSource.camera)
                    : null,
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

  // ─── 批量模式UI ───

  Widget _buildBatchSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _isInitialized ? _pickBatchImages : null,
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
          // 缩略图预览
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
