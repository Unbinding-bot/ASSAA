import 'dart:ui';

import '../math3d.dart';

/// One item in a waypoint's sub-checklist (spec §5 "Minesweeper" flags).
class ChecklistItem {
  final String id;
  String label;
  bool checked;

  ChecklistItem({
    required this.id,
    required this.label,
    this.checked = false,
  });

  ChecklistItem copyWith({String? label, bool? checked}) => ChecklistItem(
    id:      id,
    label:   label   ?? this.label,
    checked: checked ?? this.checked,
  );

  Map<String, dynamic> toJson() => {
    'id':      id,
    'label':   label,
    'checked': checked,
  };

  factory ChecklistItem.fromJson(Map<String, dynamic> j) => ChecklistItem(
    id:      j['id']      as String,
    label:   j['label']   as String,
    checked: j['checked'] as bool? ?? false,
  );
}

/// A user-placed map waypoint (spec §5).
///
/// [position] is in the same 2-D/3-D coordinate frame as the sensor nodes.
/// [color] controls the flag icon tint on the map canvas.
/// [isNavTarget] marks this flag as the current navigation destination.
class Waypoint {
  final String id;
  String label;
  Vec3 position;
  Color color;
  bool visible;
  bool isNavTarget;
  final List<ChecklistItem> checklist;

  Waypoint({
    required this.id,
    required this.label,
    required this.position,
    this.color       = const Color(0xFFFF5722),
    this.visible     = true,
    this.isNavTarget = false,
    List<ChecklistItem>? checklist,
  }) : checklist = checklist ?? [];

  /// Fraction of checklist items that are checked (0–1).
  double get progress {
    if (checklist.isEmpty) { return 0; }
    final done = checklist.where((c) => c.checked).length;
    return done / checklist.length;
  }

  Map<String, dynamic> toJson() => {
    'id':            id,
    'label':         label,
    'x':             position.x,
    'y':             position.y,
    'z':             position.z,
    'hex_color':     '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    'visible':       visible,
    'is_nav_target': isNavTarget,
    'checklist':     checklist.map((c) => c.toJson()).toList(),
  };

  factory Waypoint.fromJson(Map<String, dynamic> j) {
    final hex  = (j['hex_color'] as String).replaceFirst('#', '');
    final argb = hex.length == 6 ? 'FF$hex' : hex;
    return Waypoint(
      id:          j['id']    as String,
      label:       j['label'] as String,
      position:    Vec3(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        (j['z'] as num?)?.toDouble() ?? 0.0,
      ),
      color:       Color(int.parse(argb, radix: 16)),
      visible:     j['visible']       as bool? ?? true,
      isNavTarget: j['is_nav_target'] as bool? ?? false,
      checklist:   (j['checklist'] as List? ?? [])
          .map((c) => ChecklistItem.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}
