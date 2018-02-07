/*
 * This file is part of budgie-desktop
 * 
 * Copyright © 2015-2017 Budgie Desktop Developers
 * Copyright 2014 Josh Klar <j@iv597.com> (original Budgie work, prior to Budgie 10)
 * 
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

namespace Budgie
{


/** Spam apps */
public const string ROOT_KEY_SPAM_APPS = "spam-apps";

/** Spam categories */
public const string ROOT_KEY_SPAM_CATEGORIES = "spam-categories";

public enum NotificationCloseReason {
    EXPIRED = 1,    /** The notification expired. */
    DISMISSED = 2,  /** The notification was dismissed by the user. */
    CLOSED = 3,     /** The notification was closed by a call to CloseNotification. */
    UNDEFINED = 4   /** Undefined/reserved reasons. */
}

/**
 * We only want to make the input safe, we still need actual markup
 * support, so markup_escape won't be useful here.
 */
public static string safe_markup_string(string inp)
{
    /* Explicit copy */
    string inp2 = "" + inp;

    /* is it markup? */
    if (!(("<" in inp2) && (">" in inp2))) {
        return Markup.escape_text(inp2);
    }

    /* is it already escaped? */
    if (("&lt;" in inp2) || ("&gt;" in inp2) || ("&amp;" in inp2)) {
        return inp2;
    }

    /* Ensure it's now sane */
    if (!("&amp;" in inp2)) {
        inp2 = inp2.replace("&", "&amp;");
    }

    inp2 = inp2.replace("'", "&apos;");
    inp2 = inp2.replace("\"", "&quot;");

    try {
        if (Pango.parse_markup(inp2, -1, 0, null, null, null)) {
            return inp2;
        }
    } catch (Error e) {}

    return Markup.escape_text(inp2);
}

/**
 * Simple placeholder to use when there are no notifications
 */
public class NotificationPlaceholder : Gtk.Box
{
    public NotificationPlaceholder()
    {
        Object(spacing: 6, orientation: Gtk.Orientation.VERTICAL);

        get_style_context().add_class("dim-label");
        var image = new Gtk.Image.from_icon_name("notification-alert-symbolic", Gtk.IconSize.DIALOG);
        image.pixel_size = 64;
        pack_start(image, false, false, 6);
        var label = new Gtk.Label("<big>%s</big>".printf(_("Nothing to see here")));
        label.use_markup = true;
        pack_start(label, false, false, 0);

        halign = Gtk.Align.CENTER;
        valign = Gtk.Align.CENTER;

        this.show_all();
    }
}


[GtkTemplate (ui = "/com/solus-project/budgie/raven/notification_clone.ui")]
public class NotificationClone : Gtk.Grid
{

    [GtkChild]
    private Gtk.Image? image_icon = null;

    [GtkChild]
    private Gtk.Label? label_title = null;

    [GtkChild]
    private Gtk.Label? label_body = null;

    [GtkChild]
    private Gtk.Label? label_timestamp = null;

    public NotificationClone(NotificationWindow? target)
    {
        if (target.pixbuf != null) {
            Gdk.Pixbuf scaled_pixbuf = target.pixbuf.scale_simple(32, 32, Gdk.InterpType.NEAREST);
            this.image_icon.set_from_pixbuf(scaled_pixbuf);
        } else {
            this.image_icon.set_from_icon_name(target.icon_name, Gtk.IconSize.INVALID);
            this.image_icon.pixel_size = 32;
        }

        label_title.set_markup(safe_markup_string(target.title));
        label_body.set_markup(safe_markup_string(target.body));

        var date = new DateTime.from_unix_local(target.timestamp);

        var gnome_settings = new Settings("org.gnome.desktop.interface");
        string clock_format = gnome_settings.get_string("clock-format");
        clock_format = (clock_format == "12h") ? date.format("%l:%M %p") : date.format("%H:%M");

        label_timestamp.set_text(clock_format);
    }
}

[GtkTemplate (ui = "/com/solus-project/budgie/raven/notification.ui")]
public class NotificationWindow : Gtk.Window
{

    public NotificationsView? owner { public set ; public get; }

    public NotificationWindow(NotificationsView? owner)
    {
        Object(type: Gtk.WindowType.POPUP, type_hint: Gdk.WindowTypeHint.NOTIFICATION, owner: owner);
        resizable = false;
        skip_pager_hint = true;
        skip_taskbar_hint = true;
        set_decorated(false);

        Gdk.Visual? vis = screen.get_rgba_visual();
        if (vis != null) {
            this.set_visual(vis);
        }
        cancel = new GLib.Cancellable();

        set_default_size(NOTIFICATION_SIZE, -1);

        button_release_event.connect(()=> {
            if (!this.has_default_action) {
                return Gdk.EVENT_PROPAGATE;
            }
            did_interact = true;
            owner.ActionInvoked(this.id, "default");
            return Gdk.EVENT_STOP;
        });
    }

    void action_handler(Gtk.Button? button)
    {
        string? action_id = button.get_data("action_id");
        if (action_id == null) {
            return;
        }
        did_interact = true;

        owner.ActionInvoked(this.id, action_id);
    }

    public uint32 id;

    [GtkChild]
    private Gtk.Image? image_icon = null;

    [GtkChild]
    private Gtk.Label? label_title = null;

    [GtkChild]
    private Gtk.Label? label_body = null;

    [GtkChild]
    private Gtk.Button? button_close = null;

    [GtkChild]
    private Gtk.ButtonBox? box_actions = null;

    public string? title;
    public string? body;
    public Gdk.Pixbuf? pixbuf = null;
    public int64 timestamp;
    public string app_name;

    [GtkCallback]
    void close_clicked()
    {
        this.Closed(NotificationCloseReason.DISMISSED);
    }

    public signal void Closed(NotificationCloseReason reason);

    private string [] raw_img_search = {
        "image-data", "image_data"
    };

    /* Allow deprecated usage */
    private string[] img_search = {
        "image-path", "image_path"
    };

    private string[]? actions = null;

    HashTable<string,Variant>? hints = null;

    private string? image_path = null;

    private uint expire_id = 0;
    private uint32 timeout = 0;

    private GLib.Cancellable? cancel;
    public string? category = null;

    public bool did_interact = false;
    private bool has_default_action = false;

    /**
     * Follow the priority list for loading notification images
     * specified in the DesktopNotification spec
     */
    private async bool set_image(string? app_icon)
    {
        // try the raw hints
        foreach (string key in raw_img_search) {
            if (hints.contains(key)) {
                // if this fails for some reason, we can still fallback to the
                // other elements in the priority list
                if (yield set_image_from_data(hints.lookup(key))) {
                    return true;
                }
            }
        }

        if (yield set_from_image_path(app_icon)) {
            return true;
        } else if (hints.contains("icon_data")) { // compatibility
            return yield set_image_from_data(hints.lookup("icon_data"));
        } else {
            return false;
        }
    }

    private async bool set_from_image_path(string? app_icon)
    {
        if (this.cancel.is_cancelled()) {
            return false;
        }

        /* Update the icon. */
        string? img_path = null;
        foreach (var img in img_search) {
            var vimg_path = hints.lookup(img);
            if (vimg_path != null) {
                img_path = vimg_path.get_string();
                break;
            }
        }

        /* Fallback for filepath based icons */
        if (app_icon != null && "/" in app_icon) {
            img_path = app_icon;
        }

        /* Take the img_path */
        if (img_path == null) {
            return false;
        }

        /* Don't unnecessarily update the image */
        if (img_path == this.image_path) {
            return true;
        }

        this.image_path = img_path;

        try {
            var file = File.new_for_path(image_path);
            var ins = yield file.read_async(Priority.DEFAULT, null);
            Gdk.Pixbuf? pbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(ins, 48, 48, true, cancel);
            this.pixbuf = pbuf;
            image_icon.set_from_pixbuf(pbuf);
        } catch (Error e) {
            return false;
        }

        return true;
    }

    /**
     * Decode a raw image (iiibiiay) sent through 'hints'
     */
    private async bool set_image_from_data(Variant img)
    {
        if (this.cancel.is_cancelled()) {
            return false;
        }

        // Read the image fields
        int width           = img.get_child_value(0).get_int32();
        int height          = img.get_child_value(1).get_int32();
        int rowstride       = img.get_child_value(2).get_int32();
        bool has_alpha      = img.get_child_value(3).get_boolean();
        int bits_per_sample = img.get_child_value(4).get_int32();
        int n_channels      = img.get_child_value(5).get_int32();
        // read the raw data
        unowned uint8[] raw = (uint8[]) img.get_child_value (6).get_data();

        // rebuild and scale the image
		var pixbuf = new Gdk.Pixbuf.with_unowned_data (raw, Gdk.Colorspace.RGB,
            has_alpha, bits_per_sample, width, height, rowstride, null);
        var scaled_pixbuf = pixbuf.scale_simple(48, 48,  Gdk.InterpType.BILINEAR);

        // set the image
        if (scaled_pixbuf != null) {
            image_icon.set_from_pixbuf(scaled_pixbuf);
            return true;
        } else {
            return false;
        }
    }

    bool do_expire()
    {
        this.Closed(NotificationCloseReason.EXPIRED);
        return false;
    }

    public async void set_from_notify(uint32 id, string app_name, string app_icon,
                                        string summary, string body, HashTable<string, Variant> hints,
                                        int32 expire_timeout)
    {
        this.id = id;
        this.hints = hints;

        stop_decay();

        if (!this.cancel.is_cancelled()) {
            this.cancel.cancel();
        }
        this.cancel.reset();
        var datetime = new DateTime.now_local();
        this.timestamp = datetime.to_unix();

        bool is_img = yield this.set_image(app_icon);
        bool has_desktop = false;

        if ("desktop-entry" in hints) {
            this.app_name = hints.lookup("desktop-entry").get_string();
            has_desktop = true;
        } else {
            this.app_name = app_name;
        }

        /* Fallback to named icon if no image-path is specified */
        if (!is_img) {
            this.image_path = null;

            if (app_icon != "") {
                image_icon.set_from_icon_name(app_icon, Gtk.IconSize.INVALID);
                image_icon.pixel_size = 48;
                this.icon_name = app_icon;
            } else {
                /* Use the .desktop icon if we can */
                if (has_desktop) {
                    try {
                        string? did = this.app_name;
                        if (!did.has_suffix(".desktop")) {
                            did = "%s.desktop".printf(did);
                        }
                        var app_info = new DesktopAppInfo(did);
                        image_icon.set_from_gicon(app_info.get_icon(), Gtk.IconSize.INVALID);
                    } catch (Error e) {
                        image_icon.set_from_icon_name("mail-unread-symbolic", Gtk.IconSize.INVALID);
                        this.icon_name = "mail-unread-symbolic";
                    }
                } else {
                    image_icon.set_from_icon_name("mail-unread-symbolic", Gtk.IconSize.INVALID);
                    this.icon_name = "mail-unread-symbolic";
                }
                image_icon.pixel_size = 48;
            }
        }

        if ("category" in hints) {
            this.category = hints.lookup("category").get_string();
        }

        if (summary == "") {
            label_title.set_markup(safe_markup_string(app_name));
            this.title = app_name;
        } else {
            label_title.set_markup(safe_markup_string(summary));
            this.title = summary;
        }
    
        label_body.set_markup(safe_markup_string(body));
        this.body = body;

        this.timeout = expire_timeout;
    }

    public void set_actions(string[] actions)
    {
        if (this.actions == actions) {
            return;
        }

        if (actions.length == this.actions.length) {
            bool same = true;
            for (int i = 0; i < actions.length; i++) {
                if (actions[i] != this.actions[i]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                return;
            }
        }

        this.actions = actions;

        bool icons = hints.contains("action-icons");
        if (actions == null || actions.length == 0) {
            return;
        }
        if (actions.length % 2 != 0) {
            return;
        }

        foreach (var kid in box_actions.get_children()) {
            ulong con_id = kid.get_data("action_con");
            SignalHandler.disconnect(kid, con_id);
            kid.destroy();
        }
        for (int i = 0; i < actions.length; i++) {
            Gtk.Button? button = null;
            string action = actions[i];
            string local = actions[++i];

            if (action == "default" && local == "") {
                this.has_default_action = true;
                continue;
            }
            if (icons) {
                if (!action.has_suffix("-symbolic")) {
                    button = new Gtk.Button.from_icon_name("%s-symbolic".printf(action), Gtk.IconSize.MENU);
                } else {
                    button = new Gtk.Button.from_icon_name(action, Gtk.IconSize.MENU);
                }
                /* set action; */
            } else {
                button = new Gtk.Button.with_label(local);
                button.set_can_focus(false);
                button.set_can_default(false);
            }
            ulong con_id = button.clicked.connect(action_handler);
            button.set_data("action_con", con_id);
            button.set_data("action_id", action);
            box_actions.add(button);
        }
        box_actions.show_all();
        queue_draw();
    }

    public void begin_decay()
    {
        expire_id = Timeout.add(timeout, do_expire);
    }

    public void stop_decay()
    {
        if (expire_id > 0) {
            Source.remove(expire_id);
            expire_id = 0;
        }
    }

    public override void get_preferred_width(out int min, out int nat)
    {
        min = nat = NOTIFICATION_SIZE;
    }

    public override void get_preferred_width_for_height(int h, out int min, out int nat)
    {
        min = nat = NOTIFICATION_SIZE;
    }
}

public const int BUFFER_ZONE = 10;
public const int INITIAL_BUFFER_ZONE = 45;
public const int NOTIFICATION_SIZE = 400;

[DBus (name = "org.freedesktop.Notifications")]
public class NotificationsView : Gtk.Box
{

    string[] caps = {
        "body", "body-markup", "actions", "action-icons"
    };

    private Settings settings = new GLib.Settings("com.solus-project.budgie-panel");

    private HeaderWidget? header = null;
    private Gtk.ListBox? listbox;
    private Gtk.Button button_mute;
    private bool mute_control = false;
    private Gtk.Image image_notifications_enabled = new Gtk.Image.from_icon_name("mail-send-receive-symbolic", Gtk.IconSize.MENU);
    private Gtk.Image image_notifications_disabled = new Gtk.Image.from_icon_name("image-red-eye-symbolic", Gtk.IconSize.MENU);

    private GLib.Queue<NotificationWindow?> stack = null;

    /* Obviously we'll change this.. */
    private HashTable<uint32,NotificationWindow?> notifications;

    public async string[] get_capabilities()
    {
        return caps;
    }

    public void CloseNotification(uint32 id) {
        if (remove_notification(id)) {
            this.NotificationClosed(id, NotificationCloseReason.CLOSED);
        }
    }

    private uint32 notif_id = 0;
    [DBus (visible = false)]
    void on_notification_closed(NotificationWindow? widget, NotificationCloseReason reason)
    {
        ulong nid = widget.get_data("npack_id");

        SignalHandler.disconnect(widget, nid);
        this.NotificationClosed(widget.id, reason);

        string[] spam_apps = settings.get_strv(Budgie.ROOT_KEY_SPAM_APPS);
        string[] spam_categories = settings.get_strv(Budgie.ROOT_KEY_SPAM_CATEGORIES);
        if (reason == NotificationCloseReason.EXPIRED) {
            if (!(widget.category != null && widget.category in spam_categories) && !(widget.app_name != null && widget.app_name in spam_apps) && !widget.did_interact) {
                var clone = new NotificationClone(widget);
                clone.show_all();
                this.listbox.add(clone);
                clone.show_all();
                Raven.get_instance().UnreadNotifications();
            }
        }

        update_child_count();
        this.remove_notification(widget.id);
    }

    [DBus (visible = false)]
    bool remove_notification(uint32 id)
    {
        unowned NotificationWindow? widget = notifications.lookup(id);
        if (widget == null) {
            return false;
        }

        widget.stop_decay();

        notifications.remove(widget.id);
        stack.remove(widget);
        widget.destroy();
        return true;
    }

    [DBus (visible = false)]
    void update_child_count()
    {
        uint len = listbox.get_children().length();

        string? text = null;
        if (len > 1) {
            text = _("%u unread notifications").printf(len);
        } else if (len == 1) {
            text = _("1 unread notification");
        } else {
            text = _("No unread notifications");
        }    

        Raven.get_instance().set_notification_count(len);
        header.text = text;
    }

    public uint32 Notify(string app_name, uint32 replaces_id, string app_icon,
                           string summary, string body, string[] actions,
                           HashTable<string, Variant> hints, int32 expire_timeout)
    {
        ++notif_id;

        unowned NotificationWindow? pack = null;
        bool configure = false;

        if (replaces_id > 0) {
            pack = notifications.lookup(replaces_id);
        }

        int32 expire = expire_timeout;

        if (mute_control) {
            /* Don't show the notification */
            expire = 0;
        /* Prevent pure derpery. */
        } else if (expire_timeout < 4000 || expire_timeout > 20000) {
            expire = 4000;
        }

        if (pack == null) {
            var npack = new NotificationWindow(this);
            ulong nid = npack.Closed.connect(on_notification_closed);
            npack.set_data("npack_id", nid);
            notifications.insert(notif_id, npack);
            pack = npack;
            configure = true;
        } else {
            notifications.steal(notif_id);
            notifications.insert(notif_id, pack);
        }

        string[] actions_copy = {};

        foreach (var action in actions) {
            actions_copy += "%s".printf(action);
        }
        /* When we yield vala unrefs everything and we get double frees. GG */
        pack.set_from_notify.begin(notif_id, app_name, app_icon, summary, body, hints, expire, ()=> {
            pack.set_actions(actions_copy);

            if (configure) {
                configure_window(pack);
            } else {
                pack.begin_decay();
            }
        });
        
        return notif_id;
    }

    private void configure_window(NotificationWindow? window)
    {
        int x = 0;
        int y = 0;
        Gdk.Rectangle rect;

        unowned NotificationWindow? tail = stack.peek_head();
        var screen = Gdk.Screen.get_default();

        int mon = screen.get_primary_monitor();

        screen.get_monitor_geometry(mon, out rect);

        if (tail != null) {
            int nx;
            int ny;
            tail.get_position(out nx, out ny);
            x = nx;
            y = ny + tail.get_child().get_allocated_height() + BUFFER_ZONE;
        } else {
            x = (rect.x+rect.width) - NOTIFICATION_SIZE;
            x -= BUFFER_ZONE; /* Don't touch lip of next desktop */
            y = (rect.y) + INITIAL_BUFFER_ZONE;
        }

        stack.push_head(window);
        window.move(x, y);
        window.show_all();
        window.begin_decay();
    }


    /* Let the client know the notification was closed */
    public signal void NotificationClosed(uint32 id, uint32 reason);
    public signal void ActionInvoked(uint32 id, string action_key);

    public void GetServerInformation(out string name, out string vendor,
                                      out string version, out string spec_version) 
    {
        name = "Raven";
        vendor = "Budgie Desktop Developers";
        version = Budgie.VERSION;
        spec_version = "1.2";
    }


    [DBus (visible = false)]
    void clear_all()
    {
        listbox.foreach((c)=> listbox.remove(c));

        update_child_count();
        Raven.get_instance().ReadNotifications();
    }

    [DBus (visible = false)]
    void do_not_disturb_toggle()
    {
        if (mute_control) {
            button_mute.set_image(image_notifications_enabled);
            mute_control = false;
        } else {
            button_mute.set_image(image_notifications_disabled);
            mute_control = true;
        }
    }


    [DBus (visible = false)]
    public NotificationsView()
    {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);

        var img = new Gtk.Image.from_icon_name("list-remove-all-symbolic", Gtk.IconSize.MENU);
        img.margin_top = 4;

        var btn = new Gtk.Button.from_icon_name("list-remove-all-symbolic", Gtk.IconSize.MENU);
        btn.relief = Gtk.ReliefStyle.NONE;
        
        button_mute = new Gtk.Button();
        button_mute.set_image(image_notifications_enabled);
        button_mute.relief = Gtk.ReliefStyle.NONE;
        
        var controlButtons = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        controlButtons.pack_start(btn, false, false, 0);
        controlButtons.pack_start(button_mute, false, false, 0);

        header = new HeaderWidget(_("No new notifications"), "notification-alert-symbolic", false, null, controlButtons);
        header.margin_top = 6;

        button_mute.clicked.connect(this.do_not_disturb_toggle);
        btn.clicked.connect(this.clear_all);

        pack_start(header, false, false, 0);

        notifications = new HashTable<uint32,NotificationWindow?>(direct_hash, direct_equal);
        stack = new GLib.Queue<NotificationWindow?>();

        var scrolledwindow = new Gtk.ScrolledWindow(null, null);
        scrolledwindow.get_style_context().add_class("raven-background");
        scrolledwindow.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

        pack_start(scrolledwindow, true, true, 0);

        listbox = new Gtk.ListBox();
        var placeholder = new NotificationPlaceholder();
        listbox.set_placeholder(placeholder);
        scrolledwindow.add(listbox);

        show_all();
        update_child_count();

        serve_dbus();
    }

    [DBus (visible = false)]
    void on_bus_acquired(DBusConnection conn)
    {
        try {
            conn.register_object("/org/freedesktop/Notifications", this);
        } catch (Error e) {
            warning("Unable to register notification dbus: %s", e.message);
        }
    }

    [DBus (visible = false)]
    void serve_dbus()
    {
        Bus.own_name(BusType.SESSION, "org.freedesktop.Notifications",
            BusNameOwnerFlags.NONE,
            on_bus_acquired, null, null);
    }
}

} /* End namespace */

/*
 * Editor modelines  -  https://www.wireshark.org/tools/modelines.html
 *
 * Local variables:
 * c-basic-offset: 4
 * tab-width: 4
 * indent-tabs-mode: nil
 * End:
 *
 * vi: set shiftwidth=4 tabstop=4 expandtab:
 * :indentSize=4:tabSize=4:noTabs=true:
 */
