import 'dart:convert';
import 'dart:io';

import 'package:falcon_one_demo/models/upload_result.dart';
import 'package:http/http.dart' as http;

/// Multipart upload to Nexus incidents API.
class UploadService {
  UploadService({
    this.baseUrl = 'https://nexus.aeriaone.com/api/incidents/upload/?bypass_processing=true',
    this.officerCode = 'off-001',
  });

  final String baseUrl;
  final String officerCode;

  /// Uploads [file] with [metadata] map JSON-encoded as `raw_metadata`.
  Future<UploadResult> uploadVideo(File file, Map<String, dynamic> metadata) async {
    if (!await file.exists()) {
      return UploadResult.failure(
        httpStatus: null,
        message: 'File does not exist',
      );
    }

    final parsed = Uri.parse(baseUrl);
    final uri = parsed.replace(
      queryParameters: <String, String>{
        ...parsed.queryParameters,
        'bypass_processing': 'true',
      },
    );
    final request = http.MultipartRequest('POST', uri);
    request.fields['officer_code'] = officerCode;
    request.fields['raw_metadata'] = jsonEncode(metadata);
    request.files.add(
      await http.MultipartFile.fromPath(
        'video_file',
        file.path,
        filename: file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'video.mp4',
      ),
    );

    final client = http.Client();
    try {
      final streamed = await client.send(request);
      final response = await http.Response.fromStream(streamed);
      return UploadResult.fromHttpResponse(response.statusCode, response.body);
    } on SocketException catch (e) {
      return UploadResult.failure(httpStatus: null, message: e.message);
    } on HttpException catch (e) {
      return UploadResult.failure(httpStatus: null, message: e.message);
    } catch (e) {
      return UploadResult.failure(httpStatus: null, message: e.toString());
    } finally {
      client.close();
    }
  }

  /// STUB — uploads a captured photo to the incidents backend.
  ///
  /// The real endpoint / field contract for images is owned by the server dev
  /// and not defined yet, so this does NOT hit the network. It validates the
  /// file and returns a synthetic success so the UI flow (capture → send) can be
  /// wired and tested. Replace the body with a real multipart POST once the
  /// photo endpoint is specified.
  Future<UploadResult> uploadPhoto(File file, Map<String, dynamic> metadata) async {
    if (!await file.exists()) {
      return UploadResult.failure(httpStatus: null, message: 'File does not exist');
    }
    // TODO(server): real photo upload once the endpoint/field is defined.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return UploadResult.success(
      httpStatus: 200,
      id: 'stub-${DateTime.now().millisecondsSinceEpoch}',
      status: 'STUBBED (photo endpoint pending)',
    );
  }
}
