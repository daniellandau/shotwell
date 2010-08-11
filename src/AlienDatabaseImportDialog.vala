/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

public class AlienDatabaseImportDialog {
    private static const int MSG_NOTEBOOK_PAGE_EMPTY = 0;
    private static const int MSG_NOTEBOOK_PAGE_PROGRESS = 1;
    private static const int MSG_NOTEBOOK_PAGE_ERROR = 2;
    
    private Gtk.Dialog dialog;
    private Gtk.Builder builder;
    
    private AlienDatabaseDriver driver;
    private DiscoveredAlienDatabase? selected_database = null;
    private File? selected_file = null;
    private Gtk.FileChooserButton file_chooser;
    private Gtk.RadioButton? file_chooser_radio;
    private Gtk.Notebook message_notebook;
    private Gtk.ProgressBar prepare_progress_bar;
    private Gtk.Label error_message_label;
    private Gtk.Button ok_button;
    private Gtk.Button cancel_button;
    
    public AlienDatabaseImportDialog(string title, AlienDatabaseDriver driver) {
        this.driver = driver;
        builder = AppWindow.create_builder();
        
        dialog = builder.get_object("alien-db-import_dialog") as Gtk.Dialog;
        dialog.title = title;
        dialog.set_parent_window(AppWindow.get_instance().get_parent_window());
        dialog.set_transient_for(AppWindow.get_instance());
        
        ok_button = builder.get_object("ok_button") as Gtk.Button;
        ok_button.clicked.connect(on_ok_button_clicked);
        cancel_button = builder.get_object("cancel_button") as Gtk.Button;
        cancel_button.clicked.connect(on_cancel_button_clicked);
        file_chooser = builder.get_object("db_filechooserbutton") as Gtk.FileChooserButton;
        file_chooser.file_set.connect(on_file_chooser_file_set);
        message_notebook = builder.get_object("message_notebook") as Gtk.Notebook;
        message_notebook.set_current_page(MSG_NOTEBOOK_PAGE_EMPTY);
        prepare_progress_bar = builder.get_object("prepare_progress_bar") as Gtk.ProgressBar;
        error_message_label = builder.get_object("import_error_label") as Gtk.Label;
        
        Gtk.Box options_box = builder.get_object("options_box") as Gtk.Box;
        
        Gee.Collection<DiscoveredAlienDatabase> discovered_databases = driver.get_discovered_databases();
        if (discovered_databases.size > 0) {
            Gtk.RadioButton db_radio = null;
            foreach (DiscoveredAlienDatabase db in discovered_databases) {
                string db_radio_label =
                    _("Import from default %1$s library (%2$s)").printf(
                        driver.get_display_name(),
                        collapse_user_path(db.get_id().driver_specific_uri)
                    );
                db_radio = create_radio_button(options_box, db_radio, db, db_radio_label);
            }
            file_chooser_radio = create_radio_button(
                options_box, db_radio, null,
                _("Import from another %s database file:").printf(driver.get_display_name())
            );
        } else {
            Gtk.Label custom_file_label = new Gtk.Label(
                _("Import from a %s database file:").printf(driver.get_display_name())
            );
            options_box.pack_start(custom_file_label, true, true, 6);
        }
        set_ok_sensitivity();
    }
    
    public string collapse_user_path(string path) {
        string result = path;
        string home_dir = Environment.get_home_dir();
        if (path.has_prefix(home_dir)) {
            long cidx = home_dir.length;
            if (home_dir[home_dir.length - 1] == '/')
                cidx--;
            result = "~%s".printf(path.substring(cidx));
        }
        return result;
    }
    
    public void on_ok_button_clicked() {
        AlienDatabase? alien_db = null;
        try {
            if (selected_database != null)
                alien_db = selected_database.get_database();
            else if (selected_file != null)
                alien_db = driver.open_database_from_file(selected_file);
            if (alien_db == null) {
                message_notebook.set_current_page(MSG_NOTEBOOK_PAGE_ERROR);
                error_message_label.set_label(_("No database selected"));
            } else {
                message_notebook.set_current_page(MSG_NOTEBOOK_PAGE_PROGRESS);
                prepare_progress_bar.set_fraction(0.0);
                ok_button.set_sensitive(false);
                cancel_button.set_sensitive(false);
                spin_event_loop();
                
                SortedList<AlienDatabaseImportJob> jobs =
                    new SortedList<AlienDatabaseImportJob>(import_job_comparator);
                Gee.ArrayList<AlienDatabaseImportJob> already_imported =
                    new Gee.ArrayList<AlienDatabaseImportJob>();
                Gee.ArrayList<AlienDatabaseImportJob> failed =
                    new Gee.ArrayList<AlienDatabaseImportJob>();
                
                Gee.Collection<AlienDatabasePhoto> photos = alien_db.get_photos();
                int photo_total = photos.size;
                int photo_idx = 0;
                foreach (AlienDatabasePhoto src_photo in photos) {
                    AlienDatabaseImportSource import_source = new AlienDatabaseImportSource(src_photo);
                    
                    if (import_source.is_already_imported()) {
                        message("Skipping import of %s: checksum detected in library", 
                            import_source.get_filename());
                        already_imported.add(new AlienDatabaseImportJob(import_source));
                        
                        continue;
                    }
                    
                    jobs.add(new AlienDatabaseImportJob(import_source));
                    photo_idx++;
                    prepare_progress_bar.set_fraction((double)photo_idx / (double)photo_total);
                    spin_event_loop();
                }
                
                if (jobs.size > 0) {
                    string db_name = _("%s Database").printf(alien_db.get_display_name());
                    BatchImport batch_import = new BatchImport(jobs, db_name, alien_import_reporter,
                        failed, already_imported);
                    
                    LibraryWindow.get_app().enqueue_batch_import(batch_import, true);
                    LibraryWindow.get_app().switch_to_import_queue_page();
                }
                // clean up
                if (selected_database != null) {
                    selected_database.release_database();
                    selected_database = null;
                }
                
                dialog.destroy();
            }
        } catch (Error e) {
            message_notebook.set_current_page(MSG_NOTEBOOK_PAGE_ERROR);
            error_message_label.set_label(_("Shotwell failed to load the database file"));
            // most failures should happen before the two buttons have been set
            // to the insensitive state but you never know so set them back to the
            // normal state so that the user can interact with them
            ok_button.set_sensitive(true);
            cancel_button.set_sensitive(true);
        }
    }
    
    public void on_cancel_button_clicked() {
        dialog.destroy();
    }
    
    public void on_file_chooser_file_set() {
        selected_file = file_chooser.get_file();
        if (file_chooser_radio != null)
            file_chooser_radio.active = true;
        set_ok_sensitivity();
    }
    
    public void run() {
        dialog.show_all();
        dialog.run();
    }
    
    public Gtk.RadioButton create_radio_button(
        Gtk.Box box, Gtk.RadioButton? group, DiscoveredAlienDatabase? alien_db, string label
    ) {
        var button = new Gtk.RadioButton.with_label_from_widget (group, label);
        if (group == null) { // first radio button is active
            button.active = true;
            selected_database = alien_db;
        }
        button.toggled.connect (() => {
            if (button.active) {
                this.selected_database = alien_db;
                set_ok_sensitivity();
            }
        });
        box.pack_start(button, true, true, 6);
        return button;
    }
    
    private void set_ok_sensitivity() {
        ok_button.set_sensitive((selected_database != null || selected_file != null));
    }
    
    private int64 import_job_comparator(void *a, void *b) {
        return ((AlienDatabaseImportJob *) a)->get_exposure_time()
            - ((AlienDatabaseImportJob *) b)->get_exposure_time();
    }
}

private void alien_import_reporter(ImportManifest manifest, BatchImportRoll import_roll) {
    ImportUI.report_manifest(manifest, true);
}
