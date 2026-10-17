// Canned data for the chuk API emulator. The model entries are copied from
// api_server/model_info/models_cache.json (one provider each), so the shape is
// the real /v1/models_info shape.

/// Body of GET /v1/models_info and GET /v1/ai/models.
const String modelsInfoJson = r'''
[
  {
    "id": "deepseek/deepseek-v4-flash-0731",
    "name": "DeepSeek: DeepSeek V4 Flash 0731",
    "description": "DeepSeek V4 Flash 0731 is a sparse mixture-of-experts model from DeepSeek, with 13B active parameters out of 284B total. This re-post-trained revision is suited for coding, reasoning, and agent workflows. This is the GA release of DeepSeek V4 Flash.",
    "supports_vision": false,
    "supports_reasoning": true,
    "supports_reasoning_effort": true,
    "reasoning_mandatory": false,
    "reasoning_supported_efforts": [
      "low",
      "high",
      "max"
    ],
    "reasoning_default_effort": "high",
    "supported_efforts": [
      "none",
      "low",
      "high",
      "max"
    ],
    "supports_tools": true,
    "is_free": false,
    "context_length": 1310720,
    "max_output_tokens": 943718,
    "icon_url": "https://api.chuk.chat/v1/logos/models/deepseek.svg",
    "providers": [
      {
        "slug": "open-inference/fp8",
        "name": "OpenInference (US)",
        "pricing": {
          "prompt": 5e-08,
          "completion": 1.6e-07,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 1.3e-08,
          "cache_write": 0.0
        },
        "pricing_listed": {
          "prompt": 5e-08,
          "completion": 1.6e-07,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 1.3e-08,
          "cache_write": 0.0
        },
        "discount": 0.0,
        "speed": {
          "throughput": 15.0,
          "throughput_p95": 24.0,
          "latency_ms": 2688.0,
          "latency_ms_p95": 7082.45,
          "request_count": 157441,
          "window_minutes": 30,
          "uptime": 100.0
        },
        "context_length": 1048576,
        "max_completion_tokens": 393216,
        "is_moderated": false,
        "icon_url": "https://api.chuk.chat/v1/logos/providers/open-inference.png"
      }
    ]
  },
  {
    "id": "deepseek/deepseek-v4-pro-0813",
    "name": "DeepSeek: DeepSeek V4 Pro 0813",
    "description": "DeepSeek V4 Pro 0813 is a large-scale mixture-of-experts model from DeepSeek. This is the GA release of DeepSeek V4 Pro.",
    "supports_vision": false,
    "supports_reasoning": true,
    "supports_reasoning_effort": true,
    "reasoning_mandatory": false,
    "reasoning_supported_efforts": [
      "low",
      "high",
      "max"
    ],
    "reasoning_default_effort": "high",
    "supported_efforts": [
      "none",
      "low",
      "high",
      "max"
    ],
    "supports_tools": true,
    "is_free": false,
    "context_length": 1048576,
    "max_output_tokens": 393216,
    "icon_url": "https://api.chuk.chat/v1/logos/models/deepseek.svg",
    "providers": [
      {
        "slug": "novita/fp8",
        "name": "NovitaAI (US)",
        "pricing": {
          "prompt": 9.9e-07,
          "completion": 2.97e-06,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 3.3e-08,
          "cache_write": 0.0
        },
        "pricing_listed": {
          "prompt": 1.32e-06,
          "completion": 3.96e-06,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 4.4e-08,
          "cache_write": 0.0
        },
        "discount": 0.25,
        "speed": {
          "throughput": 59.0,
          "throughput_p95": 98.0,
          "latency_ms": 1514.0,
          "latency_ms_p95": 4985.4,
          "request_count": 2139,
          "window_minutes": 30,
          "uptime": 100.0
        },
        "context_length": 1048576,
        "max_completion_tokens": 393216,
        "is_moderated": false,
        "icon_url": "https://api.chuk.chat/v1/logos/providers/novita.png"
      }
    ]
  },
  {
    "id": "z-ai/glm-5.3-flash",
    "name": "Z.ai: GLM 5.3 Flash",
    "description": "GLM-5.3-Flash is a native multimodal model from Z.ai. It is suited for efficient coding and long-horizon agent tasks. Its hybrid sparse and linear attention architecture maintains accurate long-context behavior while reducing compute overhead.",
    "supports_vision": true,
    "supports_reasoning": true,
    "supports_reasoning_effort": true,
    "reasoning_mandatory": true,
    "reasoning_supported_efforts": [
      "low",
      "high",
      "max"
    ],
    "reasoning_default_effort": "max",
    "supported_efforts": [
      "low",
      "high",
      "max"
    ],
    "supports_tools": true,
    "is_free": false,
    "context_length": 1310720,
    "max_output_tokens": 131072,
    "icon_url": "https://api.chuk.chat/v1/logos/models/z-ai.png",
    "providers": [
      {
        "slug": "deepinfra/fp4",
        "name": "DeepInfra (US)",
        "pricing": {
          "prompt": 7.5e-08,
          "completion": 2.5e-07,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 1.5e-08,
          "cache_write": 0.0
        },
        "pricing_listed": {
          "prompt": 1.5e-07,
          "completion": 5e-07,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 3e-08,
          "cache_write": 0.0
        },
        "discount": 0.5,
        "speed": {
          "throughput": 26.0,
          "throughput_p95": 53.0,
          "latency_ms": 1626.0,
          "latency_ms_p95": 9109.4,
          "request_count": 13216,
          "window_minutes": 30,
          "uptime": 98.02
        },
        "context_length": 1048576,
        "max_completion_tokens": 131072,
        "is_moderated": false,
        "icon_url": "https://api.chuk.chat/v1/logos/providers/deepinfra.webp"
      }
    ]
  },
  {
    "id": "moonshotai/kimi-k3",
    "name": "MoonshotAI: Kimi K3",
    "description": "Kimi K3 is a 2.8T parameter open-weight multimodal reasoning model from Moonshot AI. It is suited for complex coding, knowledge work, and long-horizon agentic workflows, and is particularly strong at navigating large repositories, using tools, debugging, and iterating against images, logs, tests, and runtime feedback. Its architecture uses KDA and Attention Residuals for computational efficiency.",
    "supports_vision": true,
    "supports_reasoning": true,
    "supports_reasoning_effort": true,
    "reasoning_mandatory": false,
    "reasoning_supported_efforts": [
      "low",
      "high",
      "max"
    ],
    "reasoning_default_effort": "max",
    "supported_efforts": [
      "none",
      "low",
      "high",
      "max"
    ],
    "supports_tools": true,
    "is_free": false,
    "context_length": 1048576,
    "max_output_tokens": 943718,
    "icon_url": "https://api.chuk.chat/v1/logos/models/moonshotai.png",
    "providers": [
      {
        "slug": "relace/fp4",
        "name": "Relace",
        "pricing": {
          "prompt": 2.4e-06,
          "completion": 1.2e-05,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 2.4e-07,
          "cache_write": 0.0
        },
        "pricing_listed": {
          "prompt": 2.4e-06,
          "completion": 1.2e-05,
          "request": 0.0,
          "image": 0.0,
          "cache_read": 2.4e-07,
          "cache_write": 0.0
        },
        "discount": 0.0,
        "speed": {
          "throughput": 16.0,
          "throughput_p95": 29.2,
          "latency_ms": 1242.0,
          "latency_ms_p95": 2347.4,
          "request_count": 4337,
          "window_minutes": 30,
          "uptime": 99.86
        },
        "context_length": 1048576,
        "max_completion_tokens": 1048576,
        "is_moderated": false,
        "icon_url": "https://api.chuk.chat/v1/logos/providers/relace.png"
      }
    ]
  }
]
''';

/// A 16x16 solid PNG. `GET /v1/ai/image/file/<token>` serves it.
const String fixedPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGPQqv9PEmIY1TCqYfhqAACUCKgQCZL4/wAAAABJRU5ErkJggg==';
