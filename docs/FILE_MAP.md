# File Map

Complete map of all Dart files in the codebase.

## Root (`lib/`)
| File | Purpose |
|------|---------|
| `main.dart` | Entry point, theme/auth state, `ChukChatApp` |
| `constants.dart` | Global constants, `buildAppTheme()` |
| `platform_config.dart` | Compile-time platform/feature flags |
| `supabase_config.dart` | Supabase URL and anon key |
| `model_selector_page.dart` | Full-page model selection |

## Pages (`lib/pages/`)
| File | Purpose |
|------|---------|
| `login_page.dart` | Login/signup UI |
| `settings_page.dart` | Settings navigation hub |
| `theme_page.dart` | Theme/appearance settings |
| `customization_page.dart` | Behavior preferences |
| `account_settings_page.dart` | Account management |
| `system_prompt_page.dart` | System prompt editor |
| `about_page.dart` | App info and links |
| `pricing_page.dart` | Model pricing/credits |
| `projects_page.dart` | Projects list |
| `project_detail_page.dart` | Project detail (tabs) |
| `project_management_page.dart` | Mobile-friendly project management |
| `media_manager_page.dart` | Image management |
| `coming_soon_page.dart` | Placeholder |

### Model Selector (`lib/pages/model_selector/`)
| File | Purpose |
|------|---------|
| `models/model_info.dart` | Model/provider pricing details |

## Models (`lib/models/`)
| File | Purpose |
|------|---------|
| `chat_model.dart` | `ModelItem`, `AttachedFile` |
| `chat_stream_event.dart` | Stream event types |
| `project_model.dart` | `Project`, `ProjectFile` |

## Services (`lib/services/`)
### Auth & Security
| File | Purpose |
|------|---------|
| `supabase_service.dart` | Supabase init, session |
| `auth_service.dart` | Sign-in/up/out |
| `encryption_service.dart` | AES-256-GCM encryption |
| `password_change_service.dart` | Password updates |
| `password_revision_service.dart` | Forced logout detection |
| `profile_service.dart` | User profile management |

### Chat & Storage
| File | Purpose |
|------|---------|
| `chat_storage_service.dart` | Encrypted chat persistence |
| `chat_sync_service.dart` | Background sync (5s) |
| `streaming_chat_service.dart` | HTTP SSE streaming |
| `websocket_chat_service.dart` | WebSocket streaming |
| `streaming_manager.dart` | Concurrent streams |
| `message_composition_service.dart` | Prepare messages for API |
| `local_chat_cache_service.dart` | In-memory cache |
| `title_generation_service.dart` | AI-powered chat title generation |

### Projects
| File | Purpose |
|------|---------|
| `project_storage_service.dart` | Project CRUD |
| `project_message_service.dart` | Inject project context |

### Models
| File | Purpose |
|------|---------|
| `model_cache_service.dart` | Cache models |
| `model_capabilities_service.dart` | Model features |

### Shared service helpers
| File | Purpose |
|------|---------|
| `current_user.dart` | `CurrentUser.id` / `CurrentUser.stillOwns` — the ownership check every user-scoped static cache needs |
| `oauth_loopback_server.dart` | The desktop OAuth redirect server + its result page (GitHub, Google) |
| `workspace_file_upload.dart` | Pick + upload one workspace file, with progress callbacks and an optional size confirmation |
| `local_chat_cache_rows.dart` | Row shapes shared by the SQLite and the SharedPreferences cache |
| `streaming_manager_base.dart` | Platform-independent stream registry; the io build layers notifications and throttling on top |
| `supabase_schema_errors.dart` | `isMissingPreferencesColumn` |

### Config
| File | Purpose |
|------|---------|
| `theme_settings_service.dart` | Theme sync |
| `customization_preferences_service.dart` | Prefs sync |
| `user_preferences_service.dart` | Settings persistence |
| `api_config_service.dart` | API config |
| `api_status_service.dart` | API health |
| `network_status_service.dart` | Connectivity |

### Media
| File | Purpose |
|------|---------|
| `image_storage_service.dart` | Encrypted image storage |
| `image_compression_service.dart` | JPEG compression |
| `file_conversion_service.dart` | Doc conversion |

## Widgets (`lib/widgets/`)
| File | Purpose |
|------|---------|
| `auth_gate.dart` | Auth guard |
| `message_bubble.dart` | Message display |
| `markdown_message.dart` | Markdown rendering |
| `image_viewer.dart` | Full-screen images |
| `encrypted_image_widget.dart` | Encrypted image display |
| `document_viewer.dart` | Document preview |
| `attachment_preview_bar.dart` | Pre-send attachments |
| `model_selection_dropdown.dart` | Model dropdown |
| `credit_display.dart` | Credit balance |
| `password_strength_meter.dart` | Password strength |
| `project_file_viewer.dart` | Project file viewer dialog |
| `project_panel.dart` | Right-side project settings panel |
| `project_selection_dropdown.dart` | Project selection dropdown |

## Platform-Specific (`lib/platform_specific/`)
### Root Wrappers
| File | Purpose |
|------|---------|
| `root_wrapper.dart` | Export with conditional imports |
| `root_wrapper_io.dart` | Platform detection |
| `root_wrapper_desktop.dart` | Desktop layout |
| `root_wrapper_mobile.dart` | Mobile layout |
| `root_wrapper_stub.dart` | Stub for conditional imports |

### Sidebars
| File | Purpose |
|------|---------|
| `sidebar_desktop.dart` | Desktop nav |
| `sidebar_mobile.dart` | Mobile drawer |

### Chat (`lib/platform_specific/chat/`)
| File | Purpose |
|------|---------|
| `chat_ui_desktop.dart` | Desktop chat |
| `chat_ui_mobile.dart` | Mobile chat |
| `chat_api_service.dart` | API layer |
| `chat_model_selection_mixin.dart` | Model / mode / reasoning-effort state, shared by both chat States |
| `chat_message_edit_mixin.dart` | Edit, resend, branch, variant switch, composer attachments — shared by both chat States |
| `chat_debug_snapshot.dart` | What "copy debug chat" reads out of a chat screen, and the context block it writes |

### Chat Widgets (`lib/platform_specific/chat/widgets/`)
| File | Purpose |
|------|---------|
| `mobile_chat_widgets.dart` | Mobile-specific chat UI widgets |

### Handlers (`lib/platform_specific/chat/handlers/`)
| File | Purpose |
|------|---------|
| `streaming_message_handler.dart` | Message streaming |
| `chat_persistence_handler.dart` | Chat save/load |
| `file_attachment_handler.dart` | File attachments (mobile) |
| `desktop_file_handler.dart` | File attachments (desktop) |
| `scanned_pdf_pages.dart` | Replaces a text-layer-less PDF with its rendered pages — used by both handlers |
| `audio_recording_handler.dart` | Audio recording |
| `message_actions_handler.dart` | Copy/edit/delete |

## Utils (`lib/utils/`)
| File | Purpose |
|------|---------|
| `grain_overlay.dart` | Film grain effect |
| `color_extensions.dart` | Hex ↔ Color |
| `theme_extensions.dart` | Theme helpers |
| `input_validator.dart` | Password/email validation |
| `token_estimator.dart` | Token counting |
| `secure_token_handler.dart` | Token handling |
| `api_rate_limiter.dart` | Rate limiting |
| `exponential_backoff.dart` | Retry logic |
| `file_upload_validator.dart` | File validation |
| `upload_rate_limiter.dart` | Upload rate limiting (DoS protection) |
| `certificate_pinning.dart` | SSL certificate pinning |
| `service_error_handler.dart` | Error handling |
| `highlight_registry.dart` | Syntax highlighting |
| `json_helpers.dart` | `tryDecodeJsonObject` (HTTP error bodies), `tryParseLenientJson` (model output), `looksLikeEncryptedPayload` |
| `format_bytes.dart` | `formatBytes` — the one byte formatter |
| `url_launcher_helper.dart` | `launchExternalUrl` for footer links |
| `map_geometry.dart` | `hasPointSpread` — do these points cover more than one place |

## Constants (`lib/constants/`)
| File | Purpose |
|------|---------|
| `file_constants.dart` | File limits (10MB max, allowed extensions) |

## Core (`lib/core/`)
| File | Purpose |
|------|---------|
| `model_selection_events.dart` | Event bus for model selection |
