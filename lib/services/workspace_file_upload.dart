import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';

/// What came out of [pickAndUploadWorkspaceFile].
class WorkspaceUploadOutcome {
  const WorkspaceUploadOutcome._({this.fileName, this.error});

  /// The user closed the file picker, or the platform gave no file path.
  const WorkspaceUploadOutcome.cancelled() : this._();

  const WorkspaceUploadOutcome.uploaded(String fileName)
    : this._(fileName: fileName);

  const WorkspaceUploadOutcome.failed(String error) : this._(error: error);

  /// Name of the uploaded file, null unless the upload finished.
  final String? fileName;

  /// Message to show the user, null unless the upload failed.
  final String? error;
}

/// Asks for a file and uploads it to [workspaceId].
///
/// The callbacks report progress so the caller can drive its own widget
/// state: [onStart] once the name is known, [onProgress] per chunk,
/// [onConverting] when the server starts the markdown conversion, and
/// [onFinished] when the run ends, whatever the outcome.
Future<WorkspaceUploadOutcome> pickAndUploadWorkspaceFile({
  required String workspaceId,
  required void Function(String fileName) onStart,
  required void Function(double progress) onProgress,
  required void Function() onConverting,
  required void Function() onFinished,
}) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: FileConstants.allowedExtensions,
    allowMultiple: false,
  );

  if (result == null || result.files.isEmpty) {
    return const WorkspaceUploadOutcome.cancelled();
  }

  final file = result.files.first;
  // On web the picker hands back bytes and no path; on native it is the
  // other way round, and the path is what the conversion API needs.
  final filePath = file.path;
  final pickedBytes = file.bytes;
  if (filePath == null && pickedBytes == null) {
    return const WorkspaceUploadOutcome.cancelled();
  }

  final fileName = file.name;
  onStart(fileName);

  try {
    final fileBytes = filePath != null
        ? await File(filePath).readAsBytes()
        : pickedBytes!;

    await WorkspaceStorageService.uploadFile(
      workspaceId,
      fileName,
      fileBytes,
      fileName.split('.').last,
      filePath: filePath,
      generateMarkdown: true,
      onUploadProgress: onProgress,
      onConversionStart: onConverting,
    );
    return WorkspaceUploadOutcome.uploaded(fileName);
  } catch (error) {
    // StateError carries a message the user can act on; anything else only
    // has its toString().
    return WorkspaceUploadOutcome.failed(
      error is StateError ? error.message : error.toString(),
    );
  } finally {
    onFinished();
  }
}
