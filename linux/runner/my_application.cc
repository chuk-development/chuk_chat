#include "my_application.h"

#include <fcntl.h>
#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <sys/file.h>
#include <unistd.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

namespace {
int g_single_instance_lock_fd = -1;

bool acquire_single_instance_lock() {
  if (g_single_instance_lock_fd != -1) {
    return true;
  }

  const gchar* runtime_dir = g_get_user_runtime_dir();
  const gchar* fallback_dir = g_get_tmp_dir();
  const gchar* lock_dir =
      (runtime_dir != nullptr && runtime_dir[0] != '\0') ? runtime_dir : fallback_dir;

  g_autofree gchar* lock_path =
      g_build_filename(lock_dir, "chuk_chat_single_instance.lock", nullptr);

  const int fd = open(lock_path, O_RDWR | O_CREAT, 0666);
  if (fd == -1) {
    g_warning("Failed to open single-instance lock file: %s", lock_path);
    return false;
  }

  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return false;
  }

  g_single_instance_lock_fd = fd;
  return true;
}

void release_single_instance_lock() {
  if (g_single_instance_lock_fd == -1) {
    return;
  }

  flock(g_single_instance_lock_fd, LOCK_UN);
  close(g_single_instance_lock_fd);
  g_single_instance_lock_fd = -1;
}
}  // namespace

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GList* existing_windows =
      gtk_application_get_windows(GTK_APPLICATION(application));
  if (existing_windows != nullptr) {
    GtkWindow* existing_window = GTK_WINDOW(existing_windows->data);
    // Keep activation behavior simple and stable: always surface existing
    // window. Hide/show toggling is handled in Dart via tray + window_manager.
    gtk_widget_show(GTK_WIDGET(existing_window));
    gtk_window_deiconify(existing_window);
    gtk_window_present(existing_window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Chuk Chat");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Chuk Chat");
  }

  gtk_window_set_default_size(window, 1280, 720);
  // Show the shell window immediately so app launch feels responsive even if
  // the first Flutter frame takes a moment to render.
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000 for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Realize the view before plugin registration so rendering can start.
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  // Secondary launches should always activate the existing process.
  if (g_application_get_is_remote(application)) {
    g_application_activate(application);
    *exit_status = 0;
    return TRUE;
  }

  // If D-Bus activation is unavailable, guard with a process lock so we
  // never spin up a second full app instance (and second tray icon).
  if (!acquire_single_instance_lock()) {
    g_warning("Another Chuk Chat instance is already running.");
    *exit_status = 0;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.
  release_single_instance_lock();

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_DEFAULT_FLAGS,
                                     nullptr));
}
