#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Loads the window icon from the bundle.
//
// The icons ship as Flutter assets, so they sit beside the executable at
// data/flutter_assets/... . Resolving via /proc/self/exe rather than the
// working directory means the app can be launched from anywhere, and through
// a symlink — readlink() gives the real path either way.
static void set_window_icon(GtkWindow* window) {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return;
  }
  g_autofree gchar* bundle = g_path_get_dirname(exe);

  // Largest first: GTK scales down well, up badly.
  const int sizes[] = {512, 256, 128, 64, 48, 32, 24, 16};
  g_autoptr(GList) icons = nullptr;
  for (gsize i = 0; i < G_N_ELEMENTS(sizes); i++) {
    g_autofree gchar* name = g_strdup_printf("app_icon_%d.png", sizes[i]);
    g_autofree gchar* path = g_build_filename(
        bundle, "data", "flutter_assets", "assets", "icon", name, nullptr);
    GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path, nullptr);
    if (pixbuf != nullptr) {
      icons = g_list_append(icons, pixbuf);
    }
  }

  if (icons != nullptr) {
    // Handing GTK the whole set lets it pick per context — title bar, alt-tab
    // and the task switcher all ask for different sizes.
    gtk_window_set_icon_list(window, icons);
    g_list_free_full(g_steal_pointer(&icons), g_object_unref);
  }
}

// Slims the GNOME header bar down.
//
// The default is around 46 px of chrome carrying an application name the
// window already states in its own toolbar, plus the three window buttons.
//
// Registered for the whole screen rather than on the header bar's own style
// context. `gtk_style_context_add_provider` applies to that one widget's CSS
// node and nothing below it, so the rule for the title buttons -- which are
// children -- would never be consulted, and they alone hold the bar open at
// its default height.
//
// Colours match Chrome.panel and Chrome.divider in lib/src/ui/theme.dart, so
// the strip reads as the top edge of the application rather than as a foreign
// band above it. A change there wants mirroring here; there is no way to share
// the constant across the language boundary.
static void apply_compact_titlebar_css(void) {
  static const gchar* kCss =
      // 26 + 2 px of padding renders as 32 px overall: GTK adds four more
      // from the titlebar node the header bar sits inside, which no rule here
      // reaches. The figure is calibrated by measuring a screenshot, not
      // derived -- adjust it and measure again rather than doing the
      // arithmetic.
      "headerbar {"
      "  min-height: 26px;"
      "  padding: 1px 4px;"
      "  background-image: none;"
      "  background-color: #1C1C20;"
      "  border-bottom: 1px solid #2E2E34;"
      "  box-shadow: none;"
      "}"
      "headerbar button.titlebutton {"
      "  min-height: 0px;"
      "  min-width: 0px;"
      "  padding: 3px 7px;"
      "  margin: 0px;"
      "  border: none;"
      "  box-shadow: none;"
      "  background-image: none;"
      "}";

  GdkScreen* screen = gdk_screen_get_default();
  if (screen == nullptr) {
    return;
  }
  g_autoptr(GtkCssProvider) provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider, kCss, -1, nullptr);
  gtk_style_context_add_provider_for_screen(
      screen, GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
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
    // No title text: the application's own toolbar already carries the name
    // and the icon, immediately below. Repeating it here bought nothing and
    // was half of what made the bar tall.
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    // An empty custom title. GtkHeaderBar otherwise reserves a title/subtitle
    // box whose height it will not go below, whatever the CSS says.
    GtkWidget* no_title = gtk_label_new(nullptr);
    gtk_widget_show(no_title);
    gtk_header_bar_set_custom_title(header_bar, no_title);
    apply_compact_titlebar_css();
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
    // Still set on the window, so the task switcher and the window list have
    // something to show.
    gtk_window_set_title(window, "Morphosis");
  } else {
    gtk_window_set_title(window, "Morphosis");
  }

  set_window_icon(window);
  gtk_window_set_default_size(window, 1440, 900);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

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
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
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
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
