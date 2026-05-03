# Third-party notices

This project depends on the following third-party components. Each is used
under its own license; references below.

## Swift packages (Swift Package Manager)

| Package | License | Source |
|---|---|---|
| `huggingface/swift-transformers` (`Tokenizers`) | Apache-2.0 | https://github.com/huggingface/swift-transformers/blob/main/LICENSE |
| `vapor/postgres-nio` (`PostgresNIO`)            | MIT        | https://github.com/vapor/postgres-nio/blob/main/LICENSE.txt |
| `apple/swift-nio` (transitive)                  | Apache-2.0 | https://github.com/apple/swift-nio/blob/main/LICENSE.txt |
| `apple/swift-log`                               | Apache-2.0 | https://github.com/apple/swift-log/blob/main/LICENSE.txt |
| `swift-server/swift-service-lifecycle`          | Apache-2.0 | https://github.com/swift-server/swift-service-lifecycle/blob/main/LICENSE.txt |
| `modelcontextprotocol/swift-sdk` (`MCP`)        | MIT        | https://github.com/modelcontextprotocol/swift-sdk/blob/main/LICENSE |

## Models and assets

| Asset | License | Source |
|---|---|---|
| `sentence-transformers/all-MiniLM-L6-v2` (the embedding backend `claude-mind-mcp` ships as a Core ML conversion) | Apache-2.0 | https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2 |

The Core ML conversion pipeline lives in `scripts/convert_minilm.py`; the
converted `.mlpackage` is **not** checked in. Users install it locally with
`scripts/install_model.sh`, which writes a sidecar bundle to
`~/Library/Application Support/claude-mind/models/minilm-l6-v2/`. The Apache-2.0
license accompanies the model in the upstream Hugging Face repository.

## Apple frameworks

`Core Data`, `Core ML`, `NaturalLanguage`, and `Foundation` are used as
provided by the macOS SDK; no separate license file is required.

## Test/dev tooling (Python)

The Phase-1/2/3 quality harness uses `coremltools`, `transformers`, `torch`,
and `numpy` for one-time model conversion. None of those Python packages ship
inside the binary or source repository; they are installed into a local
`.venv` only when running `scripts/convert_minilm.py`. Their licenses apply
when running the conversion script.
