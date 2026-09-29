## [Unreleased]

- Requires plumb 0.4 and sourced-message 0.4, whose codecs encode Hash keys as Strings.
  `FormsCodec#encode_payload` now returns a String-keyed hash, and command form fields
  (`form_value`, `payload_fields`) read it by String key.

## [0.1.0] - 2026-03-22

- Initial release
