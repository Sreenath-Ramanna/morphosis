// lib/src/ui/photo_list.dart
//
// The folder's RAW files. Thumbnails come from the camera's own embedded
// JPEG — a file read and a memcpy against seconds for a demosaic, which is
// what makes a hundred-frame folder list instantly rather than after a
// minute of decoding.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme.dart';

class PhotoEntry {
  final String path;
  final String name;

  const PhotoEntry(this.path, this.name);
}

class PhotoList extends StatelessWidget {
  final List<PhotoEntry> photos;
  final int selected;
  final Map<String, Uint8List?> thumbnails;
  final ValueChanged<int> onSelect;

  const PhotoList({
    super.key,
    required this.photos,
    required this.selected,
    required this.thumbnails,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No RAW files.\nChoose a folder to begin.',
            textAlign: TextAlign.center,
            style: Chrome.label,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: photos.length,
      itemBuilder: (context, i) {
        final p = photos[i];
        final isSelected = i == selected;
        return _PhotoTile(
          entry: p,
          index: i,
          selected: isSelected,
          // A key in the map with a null value means "looked and there was
          // none"; a missing key means "not looked yet". The tile shows a
          // placeholder for the first and a spinner for the second.
          probed: thumbnails.containsKey(p.path),
          thumbnail: thumbnails[p.path],
          onTap: () => onSelect(i),
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  final PhotoEntry entry;
  final int index;
  final bool selected;
  final bool probed;
  final Uint8List? thumbnail;
  final VoidCallback onTap;

  const _PhotoTile({
    required this.entry,
    required this.index,
    required this.selected,
    required this.probed,
    required this.thumbnail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(6, 2, 6, 2),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: selected ? Chrome.panelRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? Chrome.accent.withValues(alpha: 0.8)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              height: 40,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: _thumb(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected ? Chrome.text : Chrome.textDim,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb() {
    final bytes = thumbnail;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _blank(),
      );
    }
    return _blank(spinner: !probed);
  }

  Widget _blank({bool spinner = false}) => Container(
        color: const Color(0xFF0E0E10),
        alignment: Alignment.center,
        child: spinner
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.4, color: Chrome.textDim),
              )
            : const Icon(Icons.photo_outlined,
                size: 14, color: Chrome.textDim),
      );
}
