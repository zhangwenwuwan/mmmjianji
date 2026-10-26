import 'dart:io';

import 'package:flutter/material.dart';

import 'theme.dart';

/// 看凭证大图：左右滑切图、下滑关闭。
class AttachmentViewerPage extends StatefulWidget {
  const AttachmentViewerPage({
    super.key,
    required this.paths,
    this.initialIndex = 0,
  });

  final List<String> paths;
  final int initialIndex;

  @override
  State<AttachmentViewerPage> createState() => _AttachmentViewerPageState();
}

class _AttachmentViewerPageState extends State<AttachmentViewerPage> {
  late final PageController _ctrl =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          widget.paths.length > 1
              ? '${_index + 1} / ${widget.paths.length}'
              : '凭证',
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 250) Navigator.of(context).pop();
        },
        child: PageView.builder(
          controller: _ctrl,
          itemCount: widget.paths.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) {
            final f = File(widget.paths[i]);
            if (!f.existsSync()) {
              return Center(
                child: Text('图片已丢失',
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              );
            }
            return InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: Image.file(
                  f,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text('无法打开这张图',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6))),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 小尺寸缩略图（编辑器里展示已挂的凭证）
class AttachmentThumb extends StatelessWidget {
  const AttachmentThumb({
    super.key,
    required this.path,
    this.size = 52,
    this.onTap,
    this.onRemove,
  });

  final String path;
  final double size;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final exists = File(path).existsSync();
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Palette.hairline(context),
              borderRadius: BorderRadius.circular(10),
              image: exists
                  ? DecorationImage(
                      image: FileImage(File(path)), fit: BoxFit.cover)
                  : null,
            ),
            child: exists
                ? null
                : Icon(Icons.broken_image_outlined,
                    size: 18, color: Palette.inkFaint(context)),
          ),
          if (onRemove != null)
            Positioned(
              right: -2,
              top: -2,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Palette.expense,
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: Palette.card(context), width: 1.5),
                  ),
                  child: const Icon(Icons.close, size: 11, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
