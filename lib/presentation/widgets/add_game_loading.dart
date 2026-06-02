import 'dart:async';

import 'package:flutter/material.dart';

/// Runs [task] while showing a non-dismissible loading dialog.
Future<T> runWithAddGameLoading<T>(
  BuildContext context,
  Future<T> Function(void Function(String message) updateMessage) task, {
  String initialMessage = '正在添加…',
}) async {
  final completer = Completer<T>();

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _AddGameLoadingDialog(
          initialMessage: initialMessage,
          onRun: (updateMessage) async {
            try {
              final result = await task(updateMessage);
              if (!completer.isCompleted) {
                completer.complete(result);
              }
            } catch (e, stack) {
              if (!completer.isCompleted) {
                completer.completeError(e, stack);
              }
            } finally {
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            }
          },
        );
      },
    ),
  );

  return completer.future;
}

class _AddGameLoadingDialog extends StatefulWidget {
  const _AddGameLoadingDialog({
    required this.initialMessage,
    required this.onRun,
  });

  final String initialMessage;
  final Future<void> Function(void Function(String message) updateMessage) onRun;

  @override
  State<_AddGameLoadingDialog> createState() => _AddGameLoadingDialogState();
}

class _AddGameLoadingDialogState extends State<_AddGameLoadingDialog> {
  late String _message;

  @override
  void initState() {
    super.initState();
    _message = widget.initialMessage;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(Duration.zero);
      if (!mounted) {
        return;
      }
      await widget.onRun((text) {
        if (mounted) {
          setState(() => _message = text);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                _message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
