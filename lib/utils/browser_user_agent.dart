/// The User-Agent for requests to third-party servers (maps, traffic, web).
///
/// Owner rule: outbound requests carry a plain browser User-Agent. They never
/// carry the product name, a contact address or any other identity.
const String kBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
