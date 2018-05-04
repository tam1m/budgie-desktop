/*
 * This file is part of budgie-desktop
 *
 * Copyright © 2015-2018 Budgie Desktop Developers
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

public class IconTasklist : Budgie.Plugin, Peas.ExtensionBase
{
    public Budgie.Applet get_panel_widget(string uuid) {
        return new IconTasklistApplet(uuid);
    }
}

[GtkTemplate (ui = "/com/solus-project/icon-tasklist/settings.ui")]
public class IconTasklistSettings : Gtk.Grid
{
    [GtkChild]
    private Gtk.Switch? switch_grouping;

    [GtkChild]
    private Gtk.Switch? switch_restrict;

    [GtkChild]
    private Gtk.Switch? switch_lock_icons;

    [GtkChild]
    private Gtk.Switch? switch_only_pinned;

    private GLib.Settings? settings;

    public IconTasklistSettings(GLib.Settings? settings)
    {
        this.settings = settings;
        settings.bind("grouping", switch_grouping, "active", SettingsBindFlags.DEFAULT);
        settings.bind("restrict-to-workspace", switch_restrict, "active", SettingsBindFlags.DEFAULT);
        settings.bind("lock-icons", switch_lock_icons, "active", SettingsBindFlags.DEFAULT);
        settings.bind("only-pinned", switch_only_pinned, "active", SettingsBindFlags.DEFAULT);
    }

}

public class IconTasklistApplet : Budgie.Applet
{
    private Wnck.Screen? wnck_screen = null;
    private GLib.Settings? settings = null;
    private GLib.HashTable<string, IconButton> buttons;
    private GLib.HashTable<string, string> id_map;
    private Gtk.Box? main_layout = null;
    private bool grouping = true;
    private bool restrict_to_workspace = false;
    private bool only_show_pinned = false;

    /* Applet support */
    private DesktopHelper? desktop_helper = null;
    private Budgie.AppSystem? app_system = null;

    public string uuid { public set; public get; }

    public override Gtk.Widget? get_settings_ui() {
        return new IconTasklistSettings(this.get_applet_settings(uuid));
    }

    public override bool supports_settings() {
        return true;
    }

    public IconTasklistApplet(string uuid)
    {
        GLib.Object(uuid: uuid);

        Wnck.set_client_type(Wnck.ClientType.PAGER);

        /* Get our settings working first */
        settings_schema = "com.solus-project.icon-tasklist";
        settings_prefix = "/com/solus-project/budgie-panel/instance/icon-tasklist";
        settings = this.get_applet_settings(uuid);

        /* Somewhere to store the window mappings */
        buttons = new GLib.HashTable<string, IconButton>(str_hash, str_equal);
        id_map = new GLib.HashTable<string, string>(str_hash, str_equal);
        main_layout = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);

        /* Initial bootstrap of helpers */
        this.desktop_helper = new DesktopHelper(this.settings, this.main_layout);
        wnck_screen = Wnck.Screen.get_default();
        app_system = new Budgie.AppSystem();

        /* Now hook up settings */
        settings.changed.connect(on_settings_changed);

        this.add(main_layout);

        Gtk.drag_dest_set(main_layout, Gtk.DestDefaults.ALL, DesktopHelper.targets, Gdk.DragAction.COPY);
        main_layout.drag_data_received.connect(on_drag_data_received);

        app_system.app_launched.connect((desktop_file) => {
            GLib.DesktopAppInfo? info = new GLib.DesktopAppInfo.from_filename(desktop_file);
            if (info == null) {
                return;
            }
            if (buttons.contains(info.get_id())) {
                IconButton button = buttons[info.get_id()];
                if (!button.icon.waiting) {
                    button.icon.waiting = true;
                    button.icon.animate_wait();
                }
            }
        });

        on_settings_changed("grouping");
        on_settings_changed("restrict-to-workspace");
        on_settings_changed("lock-icons");
        on_settings_changed("only-pinned");

        GLib.Timeout.add(1000, () => {
            connect_wnck_signals();
            on_active_window_changed(null);
            return false;
        });

        this.get_style_context().add_class("icon-tasklist");
        this.show_all();
    }

    private void startup()
    {
        string[] pinned = settings.get_strv("pinned-launchers");

        foreach (string launcher in pinned) {
            GLib.DesktopAppInfo? info = new GLib.DesktopAppInfo(launcher);
            if (info == null) {
                continue;
            }
            IconButton button = new IconButton(this.desktop_helper, info, true);
            button.update();
            ButtonWrapper wrapper = new ButtonWrapper(button);
            wrapper.orient = this.get_orientation();

            buttons.insert(launcher, button);

            main_layout.add(wrapper);
            this.show_all();
            wrapper.set_reveal_child(true);

            button.became_empty.connect(() => {
                buttons.remove(launcher);
                wrapper.gracefully_die();
            });
        }
    }

    private void connect_wnck_signals()
    {
        wnck_screen.class_group_opened.connect_after(on_class_group_opened);
        wnck_screen.class_group_closed.connect_after(on_class_group_closed);
        wnck_screen.window_opened.connect_after(on_window_opened);
        wnck_screen.window_closed.connect_after(on_window_closed);
        wnck_screen.active_window_changed.connect_after(on_active_window_changed);
        wnck_screen.active_workspace_changed.connect_after(update_buttons);
    }

    private void rebuild_items()
    {
        foreach (Gtk.Widget widget in this.main_layout.get_children()) {
            widget.destroy();
        }

        buttons.remove_all();

        startup();

        foreach (unowned Wnck.Window window in wnck_screen.get_windows()) {
            if (grouping) {
                on_class_group_opened(window.get_class_group());
            } else {
                on_window_opened(window);
            }
        }
    }

    private void on_settings_changed(string key)
    {
        switch (key) {
            case "grouping":
                this.grouping = settings.get_boolean(key);
                GLib.Idle.add(() => {
                    rebuild_items();
                    return false;
                });
                break;
            case "lock-icons":
                this.desktop_helper.lock_icons = settings.get_boolean(key);
                break;
            case "restrict-to-workspace":
                this.restrict_to_workspace = settings.get_boolean(key);
                break;
            case "only-pinned":
                this.only_show_pinned = settings.get_boolean(key);
                break;
        }
        if (key != "grouping") {
            update_buttons();
        }
    }

    private void update_buttons()
    {
        buttons.foreach((id, button) => {
            bool visible = true;

            if (this.restrict_to_workspace) {
                visible = button.has_window_on_workspace(this.wnck_screen.get_active_workspace());
            }

            if (this.only_show_pinned) {
                visible = button.is_pinned();
            }

            visible = visible || button.is_pinned();

            (button.get_parent() as ButtonWrapper).orient = this.get_orientation();
            (button.get_parent() as Gtk.Revealer).set_reveal_child(visible);
            button.update();
        });
    }

    private void on_drag_data_received(Gtk.Widget widget, Gdk.DragContext context, int x, int y, Gtk.SelectionData selection_data, uint item, uint time)
    {
        if (item != 0) {
            message("Invalid target type");
            return;
        }

        // id of app that is currently being dragged
        var app_id = (string)selection_data.get_data();
        ButtonWrapper? original_button = null;

        if (app_id.has_prefix("file://")) {
            app_id = app_id.split("://")[1];
            GLib.DesktopAppInfo? info = new GLib.DesktopAppInfo.from_filename(app_id.strip());
            if (info == null) {
                return;
            }
            app_id = info.get_id();
            if (buttons.contains(app_id)) {
                original_button = (buttons[app_id].get_parent() as ButtonWrapper);
            } else {
                IconButton button = new IconButton(this.desktop_helper, info, true);
                button.update();

                buttons.set(app_id, button);
                original_button = new ButtonWrapper(button);
                original_button.orient = this.get_orientation();
                button.became_empty.connect(() => {
                    buttons.remove(app_id);
                    original_button.gracefully_die();
                });
                main_layout.pack_start(original_button, false, false, 0);
            }
        } else {
            unowned IconButton? button = buttons.get(app_id) ?? buttons.get(id_map.get(app_id));
            original_button = (button != null) ? button.get_parent() as ButtonWrapper : null;
        }

        if (original_button == null) {
            return;
        }

        // Iterate through launchers
        foreach (Gtk.Widget widget1 in main_layout.get_children()) {
            ButtonWrapper current_button = (widget1 as ButtonWrapper);

            Gtk.Allocation alloc;

            current_button.get_allocation(out alloc);

            if ((get_orientation() == Gtk.Orientation.HORIZONTAL && x <= (alloc.x + (alloc.width / 2))) ||
                (get_orientation() == Gtk.Orientation.VERTICAL && y <= (alloc.y + (alloc.height / 2))))
            {
                int new_position, old_position;
                main_layout.child_get(original_button, "position", out old_position, null);
                main_layout.child_get(current_button, "position", out new_position, null);

                if (new_position == old_position) {
                    break;
                }

                if (new_position == old_position + 1) {
                    break;
                }

                if (new_position > old_position) {
                    new_position = new_position - 1;
                }

                main_layout.reorder_child(original_button, new_position);
                break;
            }

            if ((get_orientation() == Gtk.Orientation.HORIZONTAL && x <= (alloc.x + alloc.width)) ||
                (get_orientation() == Gtk.Orientation.VERTICAL && y <= (alloc.y + alloc.height)))
            {
                int new_position, old_position;
                main_layout.child_get(original_button, "position", out old_position, null);
                main_layout.child_get(current_button, "position", out new_position, null);

                if (new_position == old_position) {
                    break;
                }

                if (new_position == old_position - 1) {
                    break;
                }

                if (new_position < old_position) {
                    new_position = new_position + 1;
                }

                main_layout.reorder_child(original_button, new_position);
                break;
            }
        }
        original_button.set_transition_type(Gtk.RevealerTransitionType.NONE);
        original_button.set_reveal_child(true);

        this.desktop_helper.update_pinned();

        Gtk.drag_finish(context, true, true, time);
    }

    private void on_class_group_opened(Wnck.ClassGroup class_group)
    {
        if (!grouping) {
            return;
        }

        bool has_valid = false;
        foreach (Wnck.Window window in class_group.get_windows()) {
            if (!window.is_skip_tasklist()) {
                has_valid = true;
            }
        }

        if (!has_valid) {
            return;
        }

        GLib.DesktopAppInfo? app_info = null;

        foreach (Wnck.Window window in class_group.get_windows()) {
            app_info = app_system.query_window(window);
            if (app_info != null) {
                break;
            }
        }

        string app_id = (app_info == null) ? "NOTGOOD-%s".printf(class_group.get_id()) : app_info.get_id();
        id_map.insert(class_group.get_id(), app_id);

        if (buttons.contains(app_id)) {
            buttons.get(app_id).set_class_group(class_group);
            buttons.get(app_id).update();
            return;
        }

        IconButton button = new IconButton.from_group(this.desktop_helper, class_group, app_info);
        ButtonWrapper wrapper = new ButtonWrapper(button);
        wrapper.orient = this.get_orientation();

        buttons.insert(app_id, button);

        button.became_empty.connect(() => {
            buttons.remove(app_id);
            wrapper.gracefully_die();
        });

        main_layout.add(wrapper);
        this.show_all();
        (wrapper as Gtk.Revealer).set_reveal_child(true);
    }

    private void on_class_group_closed(Wnck.ClassGroup class_group)
    {
        if (!grouping) {
            return;
        }

        string? app_id = id_map.get(class_group.get_id());
        app_id = (app_id == null) ? "NOTGOOD-%s".printf(class_group.get_id()) : app_id;

        IconButton? button = buttons.get(app_id);

        if (button == null) {
            return;
        }

        if (button.is_pinned()) {
            button.set_class_group(null);
            button.update();
            return;
        }

        ButtonWrapper wrapper = (ButtonWrapper)button.get_parent();
        wrapper.gracefully_die();

        id_map.remove(class_group.get_id());
        buttons.remove(app_id);
    }

    private void on_window_opened(Wnck.Window window)
    {
        if (window.is_skip_tasklist()) {
            return;
        }

        GLib.DesktopAppInfo? app_info = app_system.query_window(window);
        string app_id = (app_info == null) ? "NOTGOOD-%lu".printf(window.get_xid()) : app_info.get_id();
        id_map.insert("%lu".printf(window.get_xid()), "%s|%lu".printf(app_id, window.get_xid()));
        id_map.insert(app_id, "%s|%lu".printf(app_id, window.get_xid()));

        IconButton? button = buttons.get(app_id);
        if (button == null) {
            button = buttons.get("%s|%lu".printf(app_id, window.get_xid()));
        }
        if (button != null && button.is_empty()) {
            if (!grouping) {
                button.set_wnck_window(window);
            }
            button.update();
            return;
        }


        if (grouping) {
            return;
        }

        bool pinned = (app_id in settings.get_strv("pinned-launchers"));

        button = new IconButton.from_window(this.desktop_helper, window, app_info, pinned);
        ButtonWrapper wrapper = new ButtonWrapper(button);
        wrapper.orient = this.get_orientation();

        buttons.insert("%s|%lu".printf(app_id, window.get_xid()), button);

        button.became_empty.connect(() => {
            buttons.remove("%s|%lu".printf(app_id, window.get_xid()));
            wrapper.gracefully_die();
        });

        main_layout.add(wrapper);
        this.show_all();
        wrapper.set_reveal_child(true);
    }

    private void on_window_closed(Wnck.Window window)
    {
        if (window.is_skip_tasklist()) {
            return;
        }

        string? app_id = id_map.get("%lu".printf(window.get_xid()));
        app_id = (app_id == null) ? "NOTGOOD-%lu".printf(window.get_xid()) : app_id;
        IconButton? button = buttons.get(app_id);
        if (button != null) {
            button.set_wnck_window(null);
            button.update();
        } else {
            app_id = app_id.split("|")[0];
            button = buttons.get(app_id);
        }

        if (grouping) {
            return;
        }

        if (button.is_pinned()) {
            button.set_wnck_window(null);
            button.update();
            return;
        }

        ButtonWrapper wrapper = (ButtonWrapper)button.get_parent();
        wrapper.gracefully_die();

        buttons.remove(app_id);
    }

    private void on_active_window_changed(Wnck.Window? previous_window)
    {
        foreach (IconButton button in buttons.get_values()) {
            if (button.has_window(this.desktop_helper.get_active_window())) {
                button.last_active_window = this.desktop_helper.get_active_window();
                button.attention(false);
            }
            button.update();
        }
    }


    void set_icons_size()
    {
        Wnck.set_default_icon_size(this.desktop_helper.icon_size);

        Idle.add(()=> {
            buttons.foreach((id, button) => {
                button.update_icon();
            });
            return false;
        });

        queue_resize();
        queue_draw();
    }

    /**
     * Our panel has moved somewhere, stash the positions
     */
    public override void panel_position_changed(Budgie.PanelPosition position) {
        this.desktop_helper.panel_position = position;
        this.desktop_helper.orientation = this.get_orientation();
        main_layout.set_orientation(this.desktop_helper.orientation);

        set_icons_size();
    }

    /**
     * Our panel has changed size, record the new icon sizes
     */
    public override void panel_size_changed(int panel, int icon, int small_icon)
    {
        this.desktop_helper.icon_size = small_icon;

        this.desktop_helper.panel_size = panel - 1;
        if (get_orientation() == Gtk.Orientation.HORIZONTAL) {
            this.desktop_helper.panel_size = panel - 6;
        }

        set_icons_size();
    }

    /**
     * Return our orientation in relation to the panel position
     */
    private Gtk.Orientation get_orientation() {
        switch (this.desktop_helper.panel_position) {
            case Budgie.PanelPosition.TOP:
            case Budgie.PanelPosition.BOTTOM:
                return Gtk.Orientation.HORIZONTAL;
            default:
                return Gtk.Orientation.VERTICAL;
        }
    }
}

[ModuleInit]
public void peas_register_types(TypeModule module)
{
    // boilerplate - all modules need this
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Budgie.Plugin), typeof(IconTasklist));
}
