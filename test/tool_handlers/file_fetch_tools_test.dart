import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/tool_handlers/file_fetch_tools.dart';

void main() {
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
  final pdf = Uint8List.fromList('%PDF-1.7 test'.codeUnits);

  MockClient client() => MockClient((req) async {
    switch (req.url.path) {
      case '/banner.png':
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      case '/to-router':
        return http.Response(
          '',
          302,
          headers: {'location': 'http://192.168.1.1/admin'},
        );
      case '/moved':
        return http.Response('', 301, headers: {'location': '/banner.png'});
      case '/download':
        return http.Response.bytes(
          pdf,
          200,
          headers: {
            'content-type': 'application/pdf',
            'content-disposition': 'attachment; filename="flyer.pdf"',
          },
        );
      default:
        return http.Response('nope', 404);
    }
  });

  late List<Uint8List> uploaded;
  Future<String> fakeUpload(Uint8List bytes) async {
    uploaded.add(bytes);
    return 'user/${uploaded.length}.enc';
  }

  setUp(() => uploaded = []);

  Future<List<String>> publicDns(String host) async => ['93.184.215.14'];

  test('one file is delivered as itself', () async {
    final r = await executeFetchFiles(
      {
        'files': [
          {'url': 'https://x.test/banner.png'},
        ],
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.isError, isFalse);
    expect(r.file!.filename, 'banner.png');
    expect(r.file!.mime, 'image/png');
    expect(r.file!.origin, SandboxArtifactPayload.originFetchFiles);
    expect(uploaded.single, png);
  });

  test('several files become one zip with the given names', () async {
    final r = await executeFetchFiles(
      {
        'files': [
          {'url': 'https://x.test/banner.png', 'name': 'big.png'},
          'https://x.test/banner.png',
          {'url': 'https://x.test/download'},
          {'url': 'https://x.test/missing.png'},
        ],
        'zip_name': 'messe banner',
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.isError, isFalse);
    expect(r.file!.filename, 'messe banner.zip');
    expect(r.file!.mime, 'application/zip');
    expect(r.text, contains('missing.png (HTTP 404)'));

    final archive = ZipDecoder().decodeBytes(uploaded.single);
    final names = archive.files.map((f) => f.name).toList();
    expect(names, ['big.png', 'banner.png', 'flyer.pdf']);
    expect(archive.files.last.content, pdf);
  });

  test('duplicate names get a counter', () async {
    final r = await executeFetchFiles(
      {
        'files': ['https://x.test/banner.png', 'https://x.test/banner.png'],
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    final names = ZipDecoder()
        .decodeBytes(uploaded.single)
        .files
        .map((f) => f.name)
        .toList();
    expect(names, ['banner.png', 'banner (2).png']);
    expect(r.file!.filename, 'files.zip');
  });

  test('nothing fetched is an error without a card', () async {
    final r = await executeFetchFiles(
      {
        'files': ['https://x.test/missing.png', 'file:///etc/passwd'],
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.isError, isTrue);
    expect(r.file, isNull);
    expect(r.text, contains('not an http(s) URL'));
    expect(uploaded, isEmpty);
  });

  test('a single url argument is accepted', () async {
    final r = await executeFetchFiles(
      {'url': 'https://x.test/download', 'files': null},
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.file!.filename, 'flyer.pdf');
  });

  test('a stored fetch_files block stays a file card without Agents', () {
    ContentBlock.decodesFileBlocks = false;
    addTearDown(() => ContentBlock.decodesFileBlocks = false);
    const payload = SandboxArtifactPayload(
      storagePath: 'u/1.enc',
      filename: 'a.zip',
      mime: 'application/zip',
      sizeBytes: 3,
      origin: SandboxArtifactPayload.originFetchFiles,
    );
    final ours = ContentBlock.fromJson(
      const ContentBlock.sandboxArtifact(payload).toJson(),
    );
    expect(ours.type, ContentBlockType.sandboxArtifact);
    expect(ours.sandboxArtifact!.filename, 'a.zip');

    final legacy = ContentBlock.fromJson({
      'type': 'sandboxArtifact',
      'sandboxArtifact': {'storagePath': 'u/2.enc', 'filename': 'old.txt'},
    });
    expect(legacy.type, ContentBlockType.text);
  });

  test('local and private hosts are refused, also after a redirect', () async {
    final r = await executeFetchFiles(
      {
        'files': [
          'http://127.0.0.1/x.png',
          'http://[::1]/x.png',
          'http://169.254.169.254/latest/meta-data',
          'http://100.102.91.31/x.png',
          'http://router.local/x.png',
          'https://x.test/to-router',
        ],
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.isError, isTrue);
    expect('local address not allowed'.allMatches(r.text).length, 6);
  });

  test('a name that resolves to a private address is refused', () async {
    final r = await executeFetchFiles(
      {
        'files': ['https://evil.test/banner.png'],
      },
      client: client(),
      upload: fakeUpload,
      lookup: (_) async => ['10.0.0.5'],
    );
    expect(r.isError, isTrue);
    expect(r.text, contains('local address not allowed'));
  });

  test('a redirect to a public path is followed', () async {
    final r = await executeFetchFiles(
      {
        'files': ['https://x.test/moved'],
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.file!.filename, 'banner.png');
  });

  test('an endless body stops at the size limit', () async {
    final endless = MockClient.streaming((req, body) async {
      Stream<List<int>> chunks() async* {
        final chunk = List<int>.filled(1024 * 1024, 7);
        while (true) {
          yield chunk;
        }
      }

      return http.StreamedResponse(chunks(), 200);
    });
    final r = await executeFetchFiles(
      {
        'files': ['https://x.test/huge.bin'],
      },
      client: endless,
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.isError, isTrue);
    expect(r.text, contains('too large'));
  });

  test('an entry without a url is reported, the rest still arrives', () async {
    final r = await executeFetchFiles(
      {
        'files': [
          'https://x.test/banner.png',
          {'name': 'lost.png'},
        ],
      },
      client: client(),
      upload: fakeUpload,
      lookup: publicDns,
    );
    expect(r.isError, isFalse);
    expect(r.file!.filename, 'banner.png');
    expect(r.text, contains('no usable url'));
    expect('no usable url'.allMatches(r.text).length, 1);
  });
}
