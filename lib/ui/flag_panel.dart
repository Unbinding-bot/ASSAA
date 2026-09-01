import 'package:flutter/material.dart';

import '../math3d.dart';
import '../models/app_settings.dart';
import '../models/waypoint.dart';
import '../theme.dart';

// =============================================================================
// FlagPanel — waypoint list + checklist drawer + nav-target selection
// =============================================================================
//
// Displayed as a bottom-sheet or side-drawer from the map screen.
// Shows all placed waypoints, lets the operator:
//   • Rename / delete a flag
//   • Tick checklist items
//   • Set a flag as the active navigation destination
//   • Toggle visibility on the map

class FlagPanel extends StatelessWidget {
  const FlagPanel({super.key, required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final c = settings.colors;
        return Container(
          decoration: BoxDecoration(
            color:        c.panel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border:       Border(top: BorderSide(color: c.panelBorder)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color:        c.panelBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header row
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
                child: Row(
                  children: [
                    Icon(Icons.flag, color: c.accent, size: 18),
                    const SizedBox(width: 8),
                    Text('Waypoints',
                        style: TextStyle(
                            color: c.text,
                            fontSize: 15,
                            fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                      '${settings.waypoints.length} flags',
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                    // Add flag shortcut
                    IconButton(
                      icon: Icon(Icons.add_location_alt_outlined,
                          color: c.accent, size: 20),
                      tooltip: 'Add flag at origin',
                      onPressed: () {
                        final idx = settings.waypoints.length + 1;
                        settings.addWaypoint(Waypoint(
                          id:       'flag_$idx',
                          label:    'Flag $idx',
                          position: const Vec3(0, 0, 0),
                        ));
                      },
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // Waypoint list — constrained so panel doesn't overfill screen
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: settings.waypoints.isEmpty
                    ? _EmptyState(c: c)
                    : ListView.separated(
                        shrinkWrap:  true,
                        padding:     const EdgeInsets.symmetric(vertical: 4),
                        itemCount:   settings.waypoints.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: c.panelBorder),
                        itemBuilder: (ctx, i) {
                          final wp = settings.waypoints[i];
                          return Dismissible(
                            key:       ValueKey(wp.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding:   const EdgeInsets.only(right: 20),
                              color:     c.red.withValues(alpha: 0.85),
                              child: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                  size: 22),
                            ),
                            onDismissed: (_) => settings.removeWaypoint(wp.id),
                            child: _WaypointTile(
                              wp:       wp,
                              settings: settings,
                              c:        c,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Open as a modal bottom sheet.
  static Future<void> show(BuildContext context, AppSettings settings) {
    return showModalBottomSheet(
      context:      context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => FlagPanel(settings: settings),
    );
  }
}

// =============================================================================
// _WaypointTile
// =============================================================================

class _WaypointTile extends StatelessWidget {
  const _WaypointTile({
    required this.wp,
    required this.settings,
    required this.c,
  });
  final Waypoint    wp;
  final AppSettings settings;
  final AppColors   c;

  @override
  Widget build(BuildContext context) {
    final isTarget = wp.isNavTarget;

    return ExpansionTile(
      tilePadding:  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      leading: Stack(
        alignment: Alignment.center,
        children: [
          if (isTarget)
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.accent, width: 1.5),
              ),
            ),
          Icon(Icons.flag, color: wp.color, size: 22),
        ],
      ),
      title: Text(
        wp.label,
        style: TextStyle(
          color:      isTarget ? c.accent : c.text,
          fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
          fontSize:   13,
        ),
      ),
      subtitle: Text(
        '(${wp.position.x.toStringAsFixed(1)}, '
        '${wp.position.y.toStringAsFixed(1)}) m'
        '${isTarget ? "  •  NAV TARGET" : ""}',
        style: TextStyle(
          color:    isTarget ? c.accent : c.textDim,
          fontSize: 10,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress pill (checklist completion)
          if (wp.checklist.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color:        c.accentSoft,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${(wp.progress * 100).round()}%',
                style: TextStyle(color: c.accent, fontSize: 10),
              ),
            ),
          const SizedBox(width: 4),

          // Visibility toggle
          IconButton(
            icon: Icon(
              wp.visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: c.textDim, size: 18,
            ),
            onPressed: () =>
                settings.updateWaypoint(wp.id, (w) => w.visible = !w.visible),
            tooltip: wp.visible ? 'Hide on map' : 'Show on map',
          ),

          // Delete — always visible, no need to expand
          IconButton(
            icon:    Icon(Icons.delete_outline, color: c.red, size: 18),
            tooltip: 'Delete flag',
            onPressed: () => settings.removeWaypoint(wp.id),
          ),
        ],
      ),
      children: [
        // ── Action buttons ──────────────────────────────────────────────────
        Wrap(
          spacing: 8,
          children: [
            _ActionChip(
              icon:  isTarget
                  ? Icons.explore_off_outlined
                  : Icons.explore,
              label: isTarget ? 'Clear target' : 'Set as target',
              color: c.accent,
              c:     c,
              onTap: () =>
                  settings.setNavTarget(isTarget ? null : wp.id),
            ),
            _ActionChip(
              icon:  Icons.edit_outlined,
              label: 'Rename',
              color: c.textDim,
              c:     c,
              onTap: () => _showRenameDialog(context),
            ),
            _ActionChip(
              icon:  Icons.add_task,
              label: 'Add task',
              color: c.textDim,
              c:     c,
              onTap: () => _addChecklistItem(context),
            ),
          ],
        ),

        // ── Checklist ───────────────────────────────────────────────────────
        if (wp.checklist.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...wp.checklist.map((item) => _ChecklistRow(
                item:     item,
                wp:       wp,
                settings: settings,
                c:        c,
              )),
        ],
      ],
    );
  }

  void _showRenameDialog(BuildContext context) {
    final ctrl = TextEditingController(text: wp.label);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.panel,
        title: Text('Rename flag', style: TextStyle(color: c.text)),
        content: TextField(
          controller:  ctrl,
          autofocus:   true,
          style:       TextStyle(color: c.text),
          decoration:  InputDecoration(
            hintText:  'Flag name',
            hintStyle: TextStyle(color: c.textDim),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () {
              settings.updateWaypoint(wp.id, (w) => w.label = ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: Text('Save', style: TextStyle(color: c.accent)),
          ),
        ],
      ),
    );
  }

  void _addChecklistItem(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.panel,
        title: Text('New task', style: TextStyle(color: c.text)),
        content: TextField(
          controller: ctrl,
          autofocus:  true,
          style:      TextStyle(color: c.text),
          decoration: InputDecoration(
            hintText:  'Task description',
            hintStyle: TextStyle(color: c.textDim),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) { return; }
              settings.updateWaypoint(wp.id, (w) {
                w.checklist.add(ChecklistItem(
                  id:    'task_${DateTime.now().millisecondsSinceEpoch}',
                  label: ctrl.text.trim(),
                ));
              });
              Navigator.pop(ctx);
            },
            child: Text('Add', style: TextStyle(color: c.accent)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Checklist row
// =============================================================================

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.item,
    required this.wp,
    required this.settings,
    required this.c,
  });
  final ChecklistItem item;
  final Waypoint      wp;
  final AppSettings   settings;
  final AppColors     c;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value:           item.checked,
          activeColor:     c.accent,
          checkColor:      c.bg,
          side:            BorderSide(color: c.textDim),
          onChanged: (_) => settings.updateWaypoint(
              wp.id,
              (w) {
                final idx = w.checklist.indexWhere((i) => i.id == item.id);
                if (idx >= 0) {
                  w.checklist[idx] = item.copyWith(checked: !item.checked);
                }
              }),
        ),
        Expanded(
          child: Text(
            item.label,
            style: TextStyle(
              color:     item.checked ? c.textDim : c.text,
              fontSize:  12,
              decoration: item.checked
                  ? TextDecoration.lineThrough
                  : TextDecoration.none,
            ),
          ),
        ),
        IconButton(
          icon:      Icon(Icons.close, color: c.textDim, size: 14),
          onPressed: () => settings.updateWaypoint(
              wp.id, (w) => w.checklist.removeWhere((i) => i.id == item.id)),
        ),
      ],
    );
  }
}

// =============================================================================
// Small helpers
// =============================================================================

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.c,
    required this.onTap,
  });
  final IconData     icon;
  final String       label;
  final Color        color;
  final AppColors    c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        margin:  const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 13),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.c});
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flag_outlined, size: 40,
              color: c.textDim.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            'No flags placed yet.\nTap the flag button on the map to add one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// No alias needed — using Vec3 from math3d directly.
