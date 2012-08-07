package Slic3r::GUI::SkeinPanel;
use strict;
use warnings;
use utf8;

use File::Basename qw(basename dirname);
use Slic3r::Geometry qw(X Y);
use Wx qw(:dialog :filedialog :font :icon :id :misc :notebook :panel :sizer);
use Wx::Event qw(EVT_BUTTON);
use base 'Wx::Panel';

our $last_input_file;
our $last_output_file;
our $last_config;

sub new {
    my $class = shift;
    my ($parent) = @_;
    my $self = $class->SUPER::new($parent, -1, wxDefaultPosition, wxDefaultSize, wxTAB_TRAVERSAL);
    
    $self->{tabpanel} = Wx::Notebook->new($self, -1, wxDefaultPosition, wxDefaultSize, wxNB_TOP | wxTAB_TRAVERSAL);
    $self->{tabpanel}->AddPage($self->{plater} = Slic3r::GUI::Plater->new($self->{tabpanel}), "Plater");
    $self->{options_tabs} = {};
    
    for my $tab_name (qw(print filament printer)) {
        $self->{options_tabs}{$tab_name} = ("Slic3r::GUI::Tab::" . ucfirst $tab_name)->new(
            $self->{tabpanel},
            plater              => $self->{plater},
            on_value_change     => sub { $self->{plater}->on_config_change(@_) }, # propagate config change events to the plater
        );
        $self->{tabpanel}->AddPage($self->{options_tabs}{$tab_name}, $self->{options_tabs}{$tab_name}->title);
    }
    
    my $sizer = Wx::BoxSizer->new(wxVERTICAL);
    $sizer->Add($self->{tabpanel}, 1, wxEXPAND);
    
    $sizer->SetSizeHints($self);
    $self->SetSizer($sizer);
    $self->Layout;
    
    return $self;
}

our $model_wildcard = "STL files (*.stl)|*.stl;*.STL|OBJ files (*.obj)|*.obj;*.OBJ|AMF files (*.amf)|*.amf;*.AMF;*.xml;*.XML";
our $ini_wildcard = "INI files *.ini|*.ini;*.INI";
our $gcode_wildcard = "G-code files *.gcode|*.gcode;*.GCODE";
our $svg_wildcard = "SVG files *.svg|*.svg;*.SVG";

sub do_slice {
    my $self = shift;
    my %params = @_;
    
    my $process_dialog;
    eval {
        # validate configuration
        my $config = $self->config;
        $config->validate;

        # confirm slicing of more than one copies
        my $copies = $Slic3r::Config->duplicate_grid->[X] * $Slic3r::Config->duplicate_grid->[Y];
        $copies = $Slic3r::Config->duplicate if $Slic3r::Config->duplicate > 1;
        if ($copies > 1) {
            my $confirmation = Wx::MessageDialog->new($self, "Are you sure you want to slice $copies copies?",
                                                      'Multiple Copies', wxICON_QUESTION | wxOK | wxCANCEL);
            return unless $confirmation->ShowModal == wxID_OK;
        }
        
        # select input file
        my $dir = $Slic3r::GUI::Settings->{recent}{skein_directory} || $Slic3r::GUI::Settings->{recent}{config_directory} || '';

        my $input_file;
        if (!$params{reslice}) {
            my $dialog = Wx::FileDialog->new($self, 'Choose a file to slice (STL/OBJ/AMF):', $dir, "", $model_wildcard, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
            if ($dialog->ShowModal != wxID_OK) {
                $dialog->Destroy;
                return;
            }
            $input_file = $dialog->GetPaths;
            $dialog->Destroy;
            $last_input_file = $input_file unless $params{export_svg};
        } else {
            if (!defined $last_input_file) {
                Wx::MessageDialog->new($self, "No previously sliced file.",
                                       'Error', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            if (! -e $last_input_file) {
                Wx::MessageDialog->new($self, "Previously sliced file ($last_input_file) not found.",
                                       'File Not Found', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            $input_file = $last_input_file;
        }
        my $input_file_basename = basename($input_file);
        $Slic3r::GUI::Settings->{recent}{skein_directory} = dirname($input_file);
        Slic3r::GUI->save_settings;
        
        my $print = Slic3r::Print->new(config => $config);
        $print->add_object_from_file($input_file);
        $print->validate;

        # select output file
        my $output_file = $main::opt{output};
        if ($params{reslice}) {
            $output_file = $last_output_file if defined $last_output_file;
        } elsif ($params{save_as}) {
            $output_file = $print->expanded_output_filepath($output_file);
            $output_file =~ s/\.gcode$/.svg/i if $params{export_svg};
            my $dlg = Wx::FileDialog->new($self, 'Save ' . ($params{export_svg} ? 'SVG' : 'G-code') . ' file as:', dirname($output_file),
                basename($output_file), $params{export_svg} ? $svg_wildcard : $gcode_wildcard, wxFD_SAVE);
            if ($dlg->ShowModal != wxID_OK) {
                $dlg->Destroy;
                return;
            }
            $output_file = $dlg->GetPath;
            $last_output_file = $output_file unless $params{export_svg};
            $dlg->Destroy;
        }
        
        # show processbar dialog
        $process_dialog = Wx::ProgressDialog->new('Slicing…', "Processing $input_file_basename…", 
            100, $self, 0);
        $process_dialog->Pulse;
        
        {
            my @warnings = ();
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            my %export_params = (
                output_file => $output_file,
                status_cb   => sub {
                    my ($percent, $message) = @_;
                    if (&Wx::wxVERSION_STRING =~ / 2\.(8\.|9\.[2-9])/) {
                        $process_dialog->Update($percent, "$message…");
                    }
                },
            );
            if ($params{export_svg}) {
                $print->export_svg(%export_params);
            } else {
                $print->export_gcode(%export_params);
            }
            Slic3r::GUI::warning_catcher($self)->($_) for @warnings;
        }
        $process_dialog->Destroy;
        undef $process_dialog;
        
        my $message = "$input_file_basename was successfully sliced";
        if ($print->processing_time) {
            $message .= ' in';
            my $minutes = int($print->processing_time/60);
            $message .= sprintf " %d minutes and", $minutes if $minutes;
            $message .= sprintf " %.1f seconds", $print->processing_time - $minutes*60;
        }
        $message .= ".\n";
        
        # Filament required
        $message .= sprintf "Filament required: %.1fmm (%.1fcm3).",
            $print->total_extrusion_length, $print->total_extrusion_volume;

        &Wx::wxTheApp->notify($message);
        Wx::MessageDialog->new($self, $message, 'Slicing Done!', 
            wxOK | wxICON_INFORMATION)->ShowModal;
    };
    Slic3r::GUI::catch_error($self, sub { $process_dialog->Destroy if $process_dialog });
}

sub save_config {
    my $self = shift;
    
    my $config = $self->config;
    eval {
        # validate configuration
        $config->validate;
    };
    Slic3r::GUI::catch_error($self) and return;
    
    my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    my $filename = $last_config ? basename($last_config) : "config.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save configuration as:', $dir, $filename, 
        $ini_wildcard, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = $dlg->GetPath;
        $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
        Slic3r::GUI->save_settings;
        $last_config = $file;
        $config->save($file);
    }
    $dlg->Destroy;
}

sub load_config_file {
    my $self = shift;
    my ($file) = @_;
    
    if (!$file) {
        return unless $self->check_unsaved_changes;
        my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
        my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $dir, "config.ini", 
                $ini_wildcard, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        return unless $dlg->ShowModal == wxID_OK;
        ($file) = $dlg->GetPaths;
        $dlg->Destroy;
    }
    $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
    Slic3r::GUI->save_settings;
    $last_config = $file;
    $_->load_external_config($file) for values %{$self->{options_tabs}};
}

sub load_config {
    my $self = shift;
    my ($config) = @_;
    
    foreach my $tab (values %{$self->{options_tabs}}) {
        $tab->set_value($_, $config->$_) for keys %$config;
    }
}

sub config_wizard {
    my $self = shift;

    return unless $self->check_unsaved_changes;
    if (my $config = Slic3r::GUI::ConfigWizard->new($self)->run) {
        $_->select_default_preset for values %{$self->{options_tabs}};
        $self->load_config($config);
    }
}

=head2 config

This method collects all config values from the tabs and merges them into a single config object.

=cut

sub config {
    my $self = shift;
    
    # retrieve filament presets and build a single config object for them
    my $filament_config;
    foreach my $preset_idx ($self->{plater}->filament_presets) {
        my $preset = $self->{options_tabs}{filament}->get_preset($preset_idx);
        my $config = $self->{options_tabs}{filament}->get_preset_config($preset);
        if (!$filament_config) {
            $filament_config = $config;
            next;
        }
        foreach my $opt_key (keys %$config) {
            next unless ref $filament_config->get($opt_key) eq 'ARRAY';
            push @{ $filament_config->get($opt_key) }, $config->get($opt_key)->[0];
        }
    }
    
    return Slic3r::Config->merge(
        Slic3r::Config->new_from_defaults,
        $self->{options_tabs}{print}->config,
        $self->{options_tabs}{printer}->config,
        $filament_config,
    );
}

sub set_value {
    my $self = shift;
    my ($opt_key, $value) = @_;
    
    my $changed = 0;
    foreach my $tab (values %{$self->{options_tabs}}) {
        $changed = 1 if $tab->set_value($opt_key, $value);
    }
    return $changed;
}

sub check_unsaved_changes {
    my $self = shift;
    
    my @dirty = map $_->title, grep $_->is_dirty, values %{$self->{options_tabs}};
    if (@dirty) {
        my $titles = join ', ', @dirty;
        my $confirm = Wx::MessageDialog->new($self, "You have unsaved changes ($titles). Discard changes and continue anyway?",
                                             'Unsaved Presets', wxICON_QUESTION | wxYES_NO | wxNO_DEFAULT);
        return ($confirm->ShowModal == wxID_YES);
    }
    
    return 1;
}

sub select_tab {
    my ($self, $tab) = @_;
    $self->{tabpanel}->ChangeSelection($tab);
}

1;
