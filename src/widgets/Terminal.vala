/* Terminal.vala
 *
 * Copyright 2020-2022 Paulo Queiroz <pvaqueiroz@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class Terminal.Terminal : Vte.Terminal {

  /**
   * List of available drop targets for Terminal
   */
  private enum DropTargets {
    URILIST,
    STRING,
    TEXT,
  }

  static string[] accel_envv = {
    "TERM=xterm-256color",
    "COLORTERM=truecolor",
    "TERM_PROGRAM=%s".printf (APP_NAME),
    "BLACKBOX_THEMES_DIR=%s".printf (Constants.get_user_schemes_dir ()),
    "VTE_VERSION=%u".printf (
                             Vte.MAJOR_VERSION * 10000 + Vte.MINOR_VERSION * 100 + Vte.MICRO_VERSION
    )
  };

  // Signals

  /**
   * This signal is emitted when the terminal process exits. Something should
   * listen for this signal and close the tab that contains this terminal.
   */
  public signal void exit ();

  // Properties

  public Scheme scheme  { get; set; }
  public Pid pid     { get; protected set; }

  public uint user_scrollback_lines {
    get {
      var settings = Settings.get_default ();

      switch (settings.scrollback_mode) {
      case ScrollbackMode.FIXED:     return settings.scrollback_lines;
      case ScrollbackMode.UNLIMITED: return -1;
      case ScrollbackMode.DISABLED:  return 0;
      default:
        error ("Invalid scrollback-mode %u", settings.scrollback_mode);
        return 0;
      }
    }
  }

  // Fields

  public Window window;
  private uint original_scrollback_lines;

  Settings settings;


  private void on_exit () {
    this.unparent ();
  }

  public Terminal (Window window, string? command = null, string? cwd = null) {
    Object (
            allow_hyperlink: true,
            receives_default: true,
            scroll_unit_is_pixels: true
    );

    this.original_scrollback_lines = this.scrollback_lines;

    this.window = window;

    this.hexpand = true;
    this.vexpand = true;
    this.halign = Gtk.Align.FILL;
    this.valign = Gtk.Align.FILL;

    this.child_exited.connect (this.on_child_exited);
    this.exit.connect (this.on_exit);

    this.settings = Settings.get_default ();
    ThemeProvider.get_default ().notify["current-theme"].connect (this.on_theme_changed);
    this.settings.notify["font"].connect (this.on_font_changed);
    this.settings.notify["terminal-padding"].connect (this.on_padding_changed);
    this.settings.notify["opacity"].connect (this.on_theme_changed);

    this.setup_drag_drop ();
    this.setup_regexes ();
    this.connect_signals ();
    this.bind_data ();
    this.on_theme_changed ();
    this.on_font_changed ();
    this.on_padding_changed ();

    var click = new Gtk.GestureClick () {
      button = Gdk.BUTTON_SECONDARY,
    };
    click.pressed.connect (this.show_menu);
    this.add_controller (click);

    try {
      this.spawn (command, cwd);
    } catch (Error e) {
      warning ("%s", e.message);
    }
  }

  // Methods ===================================================================

  private void setup_drag_drop () {
    var target = new Gtk.DropTarget (Type.INVALID, Gdk.DragAction.COPY);

    target.set_gtypes ({
      typeof (Gdk.FileList),
      typeof (GLib.File),
      typeof (string),
    });

    target.on_drop.connect (this.on_drag_data_received);

    this.add_controller (target);
  }

  private bool on_drag_data_received (Gtk.DropTarget target,
                                      Value value,
                                      double x,
                                      double y) {
    var vtype = value.type ();

    if (vtype == typeof (Gdk.FileList)) {
      var list = (Gdk.FileList) value.get_boxed ();

      foreach (unowned GLib.File file in list.get_files ()) {
        this.feed_child (Shell.quote (file.get_path ()).data);
        this.feed_child (" ".data);
      }

      return true;
    } else if (vtype == typeof (GLib.File)) {
      var file = (GLib.File) value.get_object ();
      var path = file ? .get_path ();

      if (path != null) {
        this.feed_child (Shell.quote (path).data);
        this.feed_child (" ".data);
      }

      return true;
    } else if (vtype == typeof (string)) {
      var text = value.get_string ();

      if (text != null) {
        this.feed_child (text.data);
      }

      return true;
    }

    warning ("You dropped something Terminal can't handle yet :(");
    return false;
  }

  private void setup_regexes () {
    foreach (unowned string str in Constants.URL_REGEX_STRINGS) {
      try {
        var reg = new Vte.Regex.for_match (
                                           str, -1, PCRE2.Flags.MULTILINE
        );
        int id = this.match_add_regex (reg, 0);
        this.match_set_cursor_name (id, "pointer");
      } catch (Error e) {
        warning (e.message);
      }
    }
  }

  private void on_font_changed () {
    this.font_desc = Pango.FontDescription.from_string (
                                                        this.settings.font
    );
  }

  private Gdk.RGBA get_background_color (Scheme theme) {
    var bg_transparent = theme.background_color.copy ();
    bg_transparent.alpha = this.settings.opacity * 0.01f;
    return bg_transparent;
  }

  private void on_theme_changed () {
    var theme_provider = ThemeProvider.get_default ();
    var theme_name = theme_provider.current_theme;
    var theme = theme_provider.themes.get (theme_name);

    if (theme == null) {
      warning ("INVALID THEME '%s'", theme_name);
      return;
    }

    var bg = this.get_background_color (theme);
    this.set_colors (
                     theme.foreground_color,
                     bg,
                     theme.palette.data
    );
  }

  private Gtk.CssProvider? padding_provider = null;
  private void on_padding_changed () {
    var pad = this.settings.get_padding ();

    if (this.padding_provider != null) {
      this.get_style_context ().remove_provider (this.padding_provider);
      this.padding_provider = null;
    }

    var provider = new Gtk.CssProvider();

    try {
      provider.load_from_data("vte-terminal { padding: %upx %upx %upx %upx; }".printf (
        pad.top,
        pad.right,
        pad.bottom,
        pad.left
      ).data);
    } catch(Error e) {
      warning(e.message);
    }

    this.get_style_context ().add_provider (
                                            this.padding_provider,
                                            999999999
    );
  }

  private void bind_data () {
    this.settings.schema.bind (
                               "terminal-cell-width",
                               this,
                               "cell-width-scale",
                               SettingsBindFlags.DEFAULT
    );

    this.settings.schema.bind (
                               "terminal-cell-height",
                               this,
                               "cell-height-scale",
                               SettingsBindFlags.DEFAULT
    );

    this.settings.bind_property (
                                 "cursor-shape",
                                 this,
                                 "cursor-shape",
                                 BindingFlags.SYNC_CREATE,
                                 null,
                                 null
    );

    this.settings.bind_property (
                                 "cursor-blink-mode",
                                 this,
                                 "cursor-blink-mode",
                                 BindingFlags.SYNC_CREATE,
                                 null,
                                 null
    );

    this.bind_property (
                        "user-scrollback-lines",
                        this,
                        "scrollback-lines",
                        BindingFlags.SYNC_CREATE,
                        null,
                        null
    );

    // Fallback scrolling makes it so that VTE handles scrolling on its own. We
    // want VTE to let GtkScrolledWindow take care of scrolling if the user
    // enabled "show scrollbars". Thus we set
    // `enable-fallback-scrolling = !show-scrollbars`
    //
    // See:
    // - https://gitlab.gnome.org/raggesilver/blackbox/-/issues/179
    // - https://gitlab.gnome.org/GNOME/vte/-/issues/336
    this.settings.bind_property (
                                 "show-scrollbars",
                                 this,
                                 "enable-fallback-scrolling",
                                 BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN,
                                 null,
                                 null
    );
  }

  private void connect_signals () {
    var kpcontroller = new Gtk.EventControllerKey ();
    kpcontroller.key_pressed.connect (this.on_key_pressed);
    this.add_controller (kpcontroller);

    var left_click_controller = new Gtk.GestureClick () {
      button = Gdk.BUTTON_PRIMARY,
    };
    left_click_controller.pressed.connect ((gesture, n_clicked, x, y) => {
      var event = left_click_controller.get_current_event ();
      var pattern = this.get_pattern_at_coords (x, y);

      if (
          (event.get_modifier_state () & Gdk.ModifierType.CONTROL_MASK) == 0 ||
          pattern == null
      ) {
        return;
      }

      Gtk.show_uri (this.window, pattern, event.get_time ());
    });
    this.add_controller (left_click_controller);

    this.settings.notify["scrollback-lines"]
     .connect (() => {
      this.notify_property ("user-scrollback-lines");
    });

    this.settings.notify["scrollback-mode"]
     .connect (() => {
      this.notify_property ("user-scrollback-lines");
    });
  }

  private void spawn (string? command, string? cwd) throws Error {
    string[] argv;
    string[] envv;
    Vte.PtyFlags flags = Vte.PtyFlags.DEFAULT;

    var settings = Settings.get_default ();
    string[] ? custom_shell_commandv = null;

    string shell;

    if (
        settings.use_custom_command &&
        settings.custom_shell_command != ""
    ) {
      Shell.parse_argv (settings.custom_shell_command, out custom_shell_commandv);
    }

    // Spawning works differently on host vs flatpak
    if (is_flatpak ()) {
      shell = fp_guess_shell () ?? "/usr/bin/bash";

      flags = Vte.PtyFlags.NO_CTTY;

      argv = {
        "/usr/bin/flatpak-spawn",
        "--host",
        "--watch-bus"
      };

      envv = fp_get_env () ?? Environ.get ();

      foreach (unowned string env in Terminal.accel_envv) {
        argv += @"--env=$(env)";
      }

      foreach (unowned string env in envv) {
        argv += @"--env=$(env)";
      }
    } else {
      envv = Environ.get ();

      foreach (unowned string env in Terminal.accel_envv) {
        envv += env;
      }

      shell = Environ.get_variable (envv, "SHELL");

      argv = {};

      flags = Vte.PtyFlags.DEFAULT;
    }

    if (custom_shell_commandv != null) {
      foreach (unowned string s in custom_shell_commandv) {
        argv += s;
      }
    } else {
      argv += shell;
      if (settings.command_as_login_shell && command == null) {
        argv += "--login";
      }
    }
    if (command != null) {
      argv += "-c";
      argv += command;
    }

    this.spawn_async (
                      flags,
                      cwd,
                      argv,
                      envv,
                      0,
                      null,
                      -1,
                      null,
                      // For some reason, if I try using `err` here vala will generate the
                      // following line at the top of this lambda function:
                      //
                      // g_return_if_fail (err != NULL);
                      //
                      // Which is insane, and does not work, since we expect error to be null
                      // almost always.
                      (_, _pid /*, err */) => {
      this.pid = _pid;
    });
  }

  /**
   * get_pattern_at_coords
   *
   * Copyright 2016-2022 Christian Hergert <chergert@redhat.com>
   * Copyright 2022 Paulo Queiroz
   *
   * The following function is work derived from GNOME Builder, which is also
   * licensed under the GNU General Public License version 3.
   *
   * Additionally, sourced from:
   * https://gitlab.gnome.org/GNOME/gnome-builder/-/blob/13302072a4ebae6bbe39dca9a7fb1eed75423371/src/libide/terminal/ide-terminal.c#L150
   */
  private string ? get_pattern_at_coords (double x, double y) {
    var col = (x / this.get_char_width ());
    var row = (y / this.get_char_height ());

    return this.match_check ((long) col, (long) row, null);
  }

  // Signal callbacks ==========================================================

  private void on_child_exited () {
    this.pid = -1;
    this.exit ();
  }

  public void show_menu (int n_pressed, double x, double y) {
    var menu = new Menu ();
    var edit_section = new Menu ();
    var preferences_section = new Menu ();
    var bottom_section = new Menu ();

    menu.append (_("New Tab"), "win.new_tab");
    menu.append (_("New Window"), "app.new-window");

    edit_section.append (_("Copy"), "win.copy");
    edit_section.append (_("Paste"), "win.paste");

    menu.append_section (null, edit_section);

    preferences_section.append (_("Preferences…"), "win.edit_preferences");
    menu.append_section (null, preferences_section);

    bottom_section.append (_("About Accelerator…"), "app.about");
    menu.append_section (null, bottom_section);

    var pop = new Gtk.PopoverMenu.from_model (menu);

    Gdk.Rectangle r = { 0 };

    r.x = (int) (x + Settings.get_default ().get_padding ().left);
    r.y = (int) (y + Settings.get_default ().get_padding ().bottom);

    pop.closed.connect_after (() => {
      pop.destroy ();
    });

    pop.set_parent (this);
    pop.set_has_arrow (false);
    pop.set_pointing_to (r);
    pop.popup ();
  }

  private bool on_key_pressed (uint keyval,
                               uint keycode,
                               Gdk.ModifierType state) {
    if ((state & Gdk.ModifierType.CONTROL_MASK) == 0) {
      return false;
    }

    switch (Gdk.keyval_name (keyval)) {
    case "c": {
      if (
          this.get_has_selection () &&
          Settings.get_default ().easy_copy_paste
      ) {
        this.do_copy_clipboard ();
        this.unselect_all ();
        return true;
      }
      return false;
    }
    case "v": {
      if (Settings.get_default ().easy_copy_paste) {
        this.do_paste_clipboard ();
        return true;
      }
      return false;
    }
    }

    return false;
  }

  public void zoom_in () {
    this.font_scale = double.min (10, this.font_scale + 0.1);
  }

  public void zoom_out () {
    this.font_scale = double.max (0.1, this.font_scale - 0.1);
  }

  public void zoom_default () {
    this.font_scale = 1.0;
  }

  public void do_paste_clipboard () {
    // FIXME: https://gitlab.gnome.org/GNOME/vte/-/issues/2557
    // this.paste_clipboard ();
    var cb = Gdk.Display.get_default ().get_clipboard ();
    cb.read_text_async.begin (null, (_, res) => {
      try {
        var text = cb.read_text_async.end (res);
        if (text != null) {
          this.paste_text (text);
        }
      } catch (Error e) {
        warning ("%s", e.message);
      }
    });
  }

  public void do_copy_clipboard () {
    if (this.get_has_selection ()) {
      Gdk.Display.get_default ().get_clipboard ()
       .set_text (this.get_text_selected (Vte.Format.TEXT));
    }
  }

  public async void do_paste_from_selection_clipboard () {
    // This function does not seem to be working in GTK 4 yet.
    // this.paste_primary ();

    var clipboard = Gdk.Display.get_default ().get_primary_clipboard ();
    try {
      var text = yield clipboard.read_text_async (null);

      this.paste_text (text);
    } catch (Error e) {
      warning ("%s", e.message);
    }
  }
}
