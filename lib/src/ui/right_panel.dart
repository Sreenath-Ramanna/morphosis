// lib/src/ui/right_panel.dart
//
// The three-tab right-hand panel and its tab strip.
//
// A hand-built strip rather than a Material TabBar: at 320 px wide the
// default's ink ripples, indicator weight and 48 px minimum height all have to
// be fought, and the active tab has to be readable from the state object
// anyway — the canvas changes behaviour in crop mode, so it cannot be private
// to a TabController.

import 'package:flutter/material.dart';

import 'theme.dart';

enum EditorTab {
  colour('Colour', Icons.tune),
  crop('Crop', Icons.crop_rotate),
  masks('Masks', Icons.filter_center_focus);

  const EditorTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

class TabStrip extends StatelessWidget {
  final EditorTab active;
  final ValueChanged<EditorTab> onChanged;

  /// Tabs that cannot be opened yet, shown but inert.
  final Set<EditorTab> disabled;

  const TabStrip({
    super.key,
    required this.active,
    required this.onChanged,
    this.disabled = const {},
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: const BoxDecoration(
        color: Chrome.panel,
        border: Border(bottom: BorderSide(color: Chrome.divider)),
      ),
      child: Row(
        children: [
          for (final tab in EditorTab.values)
            Expanded(
              child: _Tab(
                tab: tab,
                selected: tab == active,
                enabled: !disabled.contains(tab),
                onTap: () => onChanged(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final EditorTab tab;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _Tab({
    required this.tab,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colour = !enabled
        ? Chrome.textDim.withValues(alpha: 0.35)
        : (selected ? Chrome.text : Chrome.textDim);

    return Tooltip(
      message: enabled ? '' : 'Not implemented yet',
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? Chrome.accent : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tab.icon, size: 14, color: colour),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  tab.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colour,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the third tab shows until it exists.
///
/// Present rather than hidden on purpose: the tab is part of the plan, and a
/// strip that grows a new entry later moves the other two under the user's
/// cursor. Saying what it will do also stops it reading as a bug.
class MasksPanel extends StatelessWidget {
  const MasksPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_center_focus,
                size: 30, color: Chrome.textDim),
            const SizedBox(height: 14),
            const Text('Masks',
                style: TextStyle(fontSize: 14, color: Chrome.text)),
            const SizedBox(height: 8),
            Text(
              'Selections that confine an adjustment to part of the frame — '
              'so an exposure or a colour change applies to a sky, a face or '
              'a shadow rather than to everything.',
              textAlign: TextAlign.center,
              style: Chrome.label.copyWith(height: 1.45),
            ),
            const SizedBox(height: 12),
            Text('Not implemented yet.',
                style: Chrome.label.copyWith(color: Chrome.warn)),
          ],
        ),
      ),
    );
  }
}
