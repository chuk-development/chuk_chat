-- Allow `excalidraw` as an artifact type (Excalidraw scene JSON, rendered via WebView).
ALTER TABLE artifacts DROP CONSTRAINT IF EXISTS artifacts_type_valid;
ALTER TABLE artifacts ADD CONSTRAINT artifacts_type_valid CHECK (
  type IN ('code', 'markdown', 'html', 'mermaid', 'svg', 'technical_drawing', 'typst', 'excalidraw')
);
