import 'package:flutter/material.dart';

class _CommandTypeOption {
  final String value;
  final String label;

  const _CommandTypeOption({required this.value, required this.label});
}

class AddCommandButton extends StatelessWidget {
  final ValueChanged<String> onTypeChosen;
  final bool allowPathCommand;
  final bool allowWaitCommand;

  const AddCommandButton({
    super.key,
    required this.onTypeChosen,
    required this.allowPathCommand,
    this.allowWaitCommand = true,
  });

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: 'Add Command',
      onPressed: () => _showAddCommandDialog(context),
      icon: Icon(Icons.add, color: colorScheme.primary),
    );
  }

  Future<void> _showAddCommandDialog(BuildContext context) async {
    final allOptions = _getOptions();
    String query = '';

    final selectedValue = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final ColorScheme colorScheme = Theme.of(dialogContext).colorScheme;

        return StatefulBuilder(
          builder: (context, setState) {
            final filteredOptions = allOptions
                .where((option) => option.label
                    .toLowerCase()
                    .contains(query.trim().toLowerCase()))
                .toList();

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Add Command'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      autofocus: true,
                      onChanged: (value) {
                        setState(() {
                          query = value;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: 'Search commands...',
                        prefixIcon: const Icon(Icons.search_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: filteredOptions.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16.0),
                                child: Text('No matching commands'),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filteredOptions.length,
                              itemBuilder: (context, index) {
                                final option = filteredOptions[index];

                                return ListTile(
                                  dense: true,
                                  title: Text(option.label),
                                  onTap: () {
                                    Navigator.of(dialogContext)
                                        .pop(option.value);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selectedValue != null) {
      onTypeChosen.call(selectedValue);
    }
  }

  List<_CommandTypeOption> _getOptions() {
    return [
      if (allowPathCommand)
        const _CommandTypeOption(value: 'path', label: 'Follow Path'),
      const _CommandTypeOption(value: 'named', label: 'Named Command'),
      if (allowWaitCommand)
        const _CommandTypeOption(value: 'wait', label: 'Wait Command'),
      const _CommandTypeOption(
          value: 'sequential', label: 'Sequential Command Group'),
      const _CommandTypeOption(
          value: 'parallel', label: 'Parallel Command Group'),
      const _CommandTypeOption(
          value: 'deadline', label: 'Parallel Deadline Group'),
      const _CommandTypeOption(value: 'race', label: 'Parallel Race Group'),
    ];
  }
}
