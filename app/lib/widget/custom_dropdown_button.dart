import 'package:flutter/material.dart';

/// A [DropdownButton] with a custom theme.
/// Currently, there is no easy way to apply color and border radius to all [DropdownButton].
class CustomDropdownButton<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T>? onChanged;
  final bool expanded;

  const CustomDropdownButton({
    required this.value,
    required this.items,
    this.onChanged,
    this.expanded = true,
  });

  @override
  Widget build(BuildContext context) {
    final inputTheme = Theme.of(context).inputDecorationTheme;
    final border = inputTheme.border;
    final borderRadius = border is OutlineInputBorder
        ? border.borderRadius
        : BorderRadius.circular(12);

    return Material(
      color: inputTheme.fillColor,
      shape: RoundedRectangleBorder(borderRadius: borderRadius),
      child: DropdownButton<T>(
        value: value,
        isExpanded: expanded,
        underline: Container(),
        borderRadius: borderRadius,
        items: items,
        onChanged: onChanged == null
            ? null
            : (value) {
                if (value != null) {
                  onChanged!(value);
                }
              },
      ),
    );
  }
}
