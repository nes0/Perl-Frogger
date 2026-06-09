#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Curses;
use Time::HiRes qw(time usleep);

# Configuration

use constant {
    HOME_ROW  => 0,
    LOG1_ROW  => 1,
    LOG2_ROW  => 2,
    LOG3_ROW  => 3,
    LOG4_ROW  => 4,
    SAFE_ROW  => 5,
    ROAD1_ROW => 6,
    ROAD2_ROW => 7,
    ROAD3_ROW => 8,
    START_ROW => 9,
};
my $PLAY_W          = 56;
my $ROWS            = 10;
my $SCREEN_ROWS     = ( $ROWS * 2 ) + 4;
my $START_LIVES     = 3;
my $FROG_TIME       = 60;
my $FRAME_DELAY     = 30000;
my $TIME_BONUS_MAX  = 100;
my $TIME_BONUS_RATE = 2;                   # points per second remaining
my $HOME_SCORE      = 100;
my $LEVEL_BONUS     = 1000;

# Colours

my $CLR_TEXT   = 1;
my $CLR_FROG   = 2;
my $CLR_CAR    = 3;
my $CLR_LOG    = 4;
my $CLR_WATER  = 5;
my $CLR_HOME   = 6;
my $CLR_BANK   = 7;
my $CLR_HUD    = 8;
my $CLR_HILITE = 9;

# Sprites

my %SPRITE = (
    frog     => [ '00',       '/\\' ],
    car      => [ '┌─┐',      '└─┘' ],
    truck    => [ '┌───┐',    '└───┘' ],
    log      => [ '########', '########' ],
    home     => [ '::',       '::' ],
    occupied => [ '00',       '\\/' ],
);

# Globals

my $running        = 1;
my $victory        = 0;
my $score          = 0;
my $lives          = $START_LIVES;
my $frog_time_left = $FROG_TIME;
my $frog_spawn_time;
my @homes;
my @road_lanes;
my @log_lanes;
my %frog = (
    row           => START_ROW,
    x             => int( $PLAY_W / 2 ),
    attached_log  => undef,
    attached_lane => undef,
);
my $death_x;
my $death_row;
my $death_pause_until = 0;
my $death_flash       = 0;
my $blink_on          = 1;
my $last_blink_toggle = 0;
my $frog_just_died    = 0;

my $level             = 1;
my $level_pause_until = 0;
my $level_up_flash    = 0;
my $level_deaths      = 0;

# Curses Setup

sub init_screen {
    initscr();
    start_color();
    use_default_colors();
    init_pair( $CLR_TEXT,   COLOR_WHITE,   -1 );
    init_pair( $CLR_FROG,   COLOR_GREEN,   -1 );
    init_pair( $CLR_CAR,    COLOR_RED,     -1 );
    init_pair( $CLR_LOG,    COLOR_YELLOW,  -1 );
    init_pair( $CLR_WATER,  COLOR_CYAN,    -1 );
    init_pair( $CLR_HOME,   COLOR_MAGENTA, -1 );
    init_pair( $CLR_BANK,   COLOR_GREEN,   -1 );
    init_pair( $CLR_HUD,    COLOR_WHITE,   COLOR_BLUE );
    init_pair( $CLR_HILITE, COLOR_RED,     COLOR_BLUE );
    cbreak();
    noecho();
    keypad(1);
    nodelay(1);
    curs_set(0);
}

# Geometry Helpers

sub row_y {
    my ($logical_row) = @_;
    return 2 + ( $logical_row * 2 );
}

sub clamp {
    my ( $value, $min, $max ) = @_;
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

# Frog State

sub reset_frog {
    %frog = (
        row => START_ROW,
        x   => int( $PLAY_W / 2 ),
        w   => 2,
        h   => 2,
    );
    $frog_spawn_time = time();
    $frog_time_left  = $FROG_TIME;

    # allow next death to be counted
    $frog_just_died = 0;
}

# Home Slots

sub init_homes {
    @homes = (
        { x => 5,  occupied => 0 },
        { x => 18, occupied => 0 },
        { x => 31, occupied => 0 },
        { x => 44, occupied => 0 },
    );
}

# Road Lanes

sub init_roads {
    @road_lanes = (
        {
            row        => ROAD1_ROW,
            dir        => 1,
            sprite     => $SPRITE{truck},
            base_speed => 0.10,
            speed      => 0.10,
            timer      => time(),
            vehicles => [ { x => 0 }, { x => 14 }, { x => 28 }, { x => 42 }, ],
        },
        {
            row        => ROAD2_ROW,
            dir        => -1,
            sprite     => $SPRITE{car},
            base_speed => 0.18,
            speed      => 0.18,
            timer      => time(),
            vehicles   => [ { x => 8 }, { x => 24 }, { x => 40 }, ],
        },
        {
            row        => ROAD3_ROW,
            dir        => 1,
            sprite     => $SPRITE{car},
            base_speed => 0.07,
            speed      => 0.07,
            timer      => time(),
            vehicles => [ { x => 4 }, { x => 18 }, { x => 32 }, { x => 46 }, ],
        },
    );
}

# Log Lanes

sub init_logs {
    @log_lanes = (
        {
            row        => LOG1_ROW,
            dir        => 1,
            base_speed => 0.35,
            speed      => 0.35,
            timer      => time(),
            logs       => [
                { x => 0,  len => 10 },
                { x => 20, len => 10 },
                { x => 40, len => 10 },
            ],
        },
        {
            row        => LOG2_ROW,
            dir        => -1,
            base_speed => 0.45,
            speed      => 0.45,
            timer      => time(),
            logs       => [ { x => 5, len => 12 }, { x => 28, len => 12 }, ],
        },
        {
            row        => LOG3_ROW,
            dir        => 1,
            base_speed => 0.40,
            speed      => 0.40,
            timer      => time(),
            logs       => [
                { x => 2,  len => 9 },
                { x => 22, len => 9 },
                { x => 42, len => 9 },
            ],
        },
        {
            row        => LOG4_ROW,
            dir        => -1,
            base_speed => 0.50,
            speed      => 0.50,
            timer      => time(),
            logs       => [ { x => 10, len => 11 }, { x => 35, len => 11 }, ],
        },
    );
}

sub apply_level_difficulty {
    for my $lane (@road_lanes) {
        $lane->{speed} = $lane->{base_speed} / ( 1 + ( $level - 1 ) * 0.15 );
    }
    for my $lane (@log_lanes) {
        $lane->{speed} = $lane->{base_speed} / ( 1 + ( $level - 1 ) * 0.10 );
    }
}

# Lives

sub lose_life {
    return if $frog_just_died;
    $frog_just_died = 1;
    $lives--;

    # track deaths this level
    $level_deaths++;

    # store death position
    $death_x   = $frog{x};
    $death_row = $frog{row};

    # ALWAYS trigger death pause, even for last life
    $death_flash       = 1;
    $death_pause_until = time() + 1.0;
    $blink_on          = 1;
    $last_blink_toggle = time();
}

# Initialisation

init_screen();
init_homes();
init_roads();
init_logs();
reset_frog();

END {
    endwin();
}

# Keyboard Handling

sub handle_input {
    my $ch = getch();
    return unless defined $ch;
    if ( $ch eq 'q' || $ch eq 'Q' ) {
        $running = 0;
        return;
    }
    if ( $ch eq 'w' || $ch eq 'W' ) {
        $frog{row}--
          if $frog{row} > HOME_ROW;
    }
    elsif ( $ch eq 's' || $ch eq 'S' ) {
        $frog{row}++
          if $frog{row} < START_ROW;
    }
    elsif ( $ch eq 'a' || $ch eq 'A' ) {
        $frog{x} -= 2;
    }
    elsif ( $ch eq 'd' || $ch eq 'D' ) {
        $frog{x} += 2;
    }
    $frog{x} = clamp( $frog{x}, 0, $PLAY_W - $frog{w} );
}

# Timer

sub update_timer {
    my $elapsed = int( time() - $frog_spawn_time );
    $frog_time_left = $FROG_TIME - $elapsed;
    if ( $frog_time_left <= 0 ) {
        lose_life();
    }
}

# Vehicle Movement

sub update_roads {
    my $now = time();
    for my $lane (@road_lanes) {
        next
          if ( $now - $lane->{timer} ) < $lane->{speed};
        $lane->{timer} = $now;
        for my $vehicle ( @{ $lane->{vehicles} } ) {
            $vehicle->{x} += $lane->{dir};
            if ( $lane->{dir} > 0 ) {
                if ( $vehicle->{x} > $PLAY_W - length $lane->{sprite}[0] ) {
                    $vehicle->{x} = -6;
                }
            }
            else {
                if ( $vehicle->{x} < -6 ) {
                    $vehicle->{x} = $PLAY_W - length $lane->{sprite}[0];
                }
            }
        }
    }
}

sub update_river_attachment {

    return
      unless $frog{row} >= LOG1_ROW
      && $frog{row} <= LOG4_ROW;

    my ($lane) = grep { $_->{row} == $frog{row} } @log_lanes;
    return unless $lane;

    my $log = frog_on_log($lane);

    if ( !$log ) {
        $frog{attached_log}  = undef;
        $frog{attached_lane} = undef;
        lose_life();
        return;
    }

    $frog{attached_log}  = $log;
    $frog{attached_lane} = $lane;
}

# Log Movement

sub update_logs {
    my $now = time();
    for my $lane (@log_lanes) {
        next if ( $now - $lane->{timer} ) < $lane->{speed};
        $lane->{timer} = $now;
        for my $log ( @{ $lane->{logs} } ) {
            my $old_x = $log->{x};
            $log->{x} += $lane->{dir};
            if ( $lane->{dir} > 0 ) {
                $log->{x} = -$log->{len} if $log->{x} > $PLAY_W;
            }
            else {
                $log->{x} = $PLAY_W if $log->{x} + $log->{len} < 0;
            }

            # 🔥 ONLY MOVE FROG IF IT IS ON THIS EXACT LOG
            if ( defined $frog{attached_log} && $frog{attached_log} == $log ) {
                $frog{x} += $lane->{dir};
            }
        }
    }
}

# Road Collision

sub frog_hits_vehicle {
    my ( $vx, $size ) = @_;
    my $v_left  = $vx;
    my $v_right = $vx + $size;
    my $f_left  = $frog{x};
    my $f_right = $frog{x} + 1;
    return $f_right >= $v_left && $f_left <= $v_right;
}

sub check_road_collisions {
    return
      unless $frog{row} >= ROAD1_ROW
      && $frog{row} <= ROAD3_ROW;
    for my $lane (@road_lanes) {
        next
          unless $lane->{row} == $frog{row};
        for my $vehicle ( @{ $lane->{vehicles} } ) {
            if ( frog_hits_vehicle( $vehicle->{x}, length $lane->{sprite}[0] ) )
            {
                lose_life();
                return;
            }
        }
    }
}

# Log Support Test

sub frog_on_log {

    my ($lane) = @_;

    for my $log ( @{ $lane->{logs} } ) {

        my $left  = $log->{x};
        my $right = $log->{x} + $log->{len} - 1;

        if ( $frog{x} >= $left && $frog{x} <= $right ) {
            return $log;
        }
    }

    return undef;
}

# River Logic

sub check_river {

    return
      unless $frog{row} >= LOG1_ROW
      && $frog{row} <= LOG4_ROW;

    my ($lane) = grep { $_->{row} == $frog{row} } @log_lanes;
    return unless $lane;

    my $log = frog_on_log($lane);

    # Not on log → die immediately
    unless ($log) {
        lose_life();
        return;
    }

    # clamp / death
    if ( $frog{x} < 0 || $frog{x} > ( $PLAY_W - 2 ) ) {
        lose_life();
        return;
    }
}

# Home Row Logic

sub award_time_bonus {
    my $elapsed = time() - $frog_spawn_time;
    my $bonus   = $TIME_BONUS_MAX - ( $elapsed * $TIME_BONUS_RATE );
    $bonus = 0 if $bonus < 0;
    $score += int($bonus);
}

sub check_home_row {
    return
      unless $frog{row} == HOME_ROW;

    sub check_level_complete {
        my $filled = 0;
        for my $home (@homes) {
            $filled++ if $home->{occupied};
        }
        if ( $filled == scalar(@homes) ) {
            $level_up_flash    = 1;
            $level_pause_until = time() + 3.0;

            # award perfect level bonus only if no deaths occurred
            if ( $level_deaths == 0 ) {
                $score += 500;    # perfect bonus
            }

            # also award standard level bonus
            $score += $LEVEL_BONUS;
            return 1;
        }
        return 0;
    }

    for my $home (@homes) {
        next
          if $home->{occupied};
        if ( abs( $frog{x} - $home->{x} ) <= 2 ) {
            $home->{occupied} = 1;
            $score += $HOME_SCORE;
            award_time_bonus();
            if ( check_level_complete() ) {

                # handled in update loop
            }
            else {
                reset_frog();
            }
            return;
        }
    }
    #
    # top row but missed
    # a valid home slot
    #
    lose_life();
}

# Game Update

sub update_game {

    # --------------------------------------------------
    # LEVEL PAUSE HANDLING
    # --------------------------------------------------
    if ($level_up_flash) {
        my $now = time();
        if ( $now >= $level_pause_until ) {
            $level_up_flash = 0;
            $level++;

            # reset board
            init_homes();
            reset_frog();

            # reapply difficulty scaling
            apply_level_difficulty();
            $level_deaths = 0;
        }
        return;    # freeze game during level transition
    }

    # --------------------------------------------------
    # DEATH STATE (freeze game)
    # --------------------------------------------------
    if ($death_flash) {
        my $now = time();

        # blink toggle
        if ( $now - $last_blink_toggle > 0.10 ) {
            $blink_on          = !$blink_on;
            $last_blink_toggle = $now;
        }

        # pause finished → now decide outcome
        if ( $now >= $death_pause_until ) {
            $death_flash    = 0;
            $blink_on       = 1;
            $frog_just_died = 0;
            if ( $lives <= 0 ) {
                $running = 0;    # game over AFTER animation
            }
            else {
                reset_frog();    # normal respawn
            }
        }
        return;                  # freeze gameplay during pause
    }

    handle_input();
    update_timer();
    update_river_attachment();
    update_roads();
    update_logs();
    check_road_collisions();
    return unless $running;
    check_river();
    return unless $running;
    check_home_row();

    if ( $frog{row} < LOG1_ROW || $frog{row} > LOG4_ROW ) {
        $frog{attached_log} = undef;
    }
}

# Drawing Helpers

sub draw_text {
    my ( $y, $x, $colour, $text ) = @_;
    attron( COLOR_PAIR($colour) );
    addstr( $y, $x, $text );
    attroff( COLOR_PAIR($colour) );
}

sub draw_fill {
    my ( $y, $colour, $char ) = @_;
    attron( COLOR_PAIR($colour) );
    addstr( $y, 0, $char x $PLAY_W );
    attroff( COLOR_PAIR($colour) );
}

sub draw_sprite {
    my ( $screen_y, $screen_x, $sprite, $colour ) = @_;
    attron( COLOR_PAIR($colour) );
    for my $row ( 0 .. $#$sprite ) {
        my $line = $sprite->[$row];
        next
          if $screen_y + $row < 0;
        addstr( $screen_y + $row, $screen_x, $line );
    }
    attroff( COLOR_PAIR($colour) );
}

# HUD

sub draw_hud {
    my $hearts  = ( '♥ ' x $lives );
    my $hearts2 = ( '♡ ' x ( 3 - $lives ) );
    attron( COLOR_PAIR($CLR_HUD) );
    addstr( 0, 0, ' ' x $PLAY_W );
    my $text = sprintf( " SCORE:%05d  LIVES:%s%s TIME:    LEVEL:%d ",
        $score, $hearts, $hearts2, $level, );
    addstr( 0, 1, $text );
    attron( COLOR_PAIR($CLR_HILITE) )
      if $frog_time_left <= 15 and $frog_time_left % 2;
    addstr( 0, 33, sprintf( "%02d", $frog_time_left ) );
    attroff( COLOR_PAIR($CLR_HUD) );
}

# Home Row

sub draw_home_row {
    my $y = row_y(HOME_ROW);
    draw_fill( $y,     $CLR_HOME, '=' );
    draw_fill( $y + 1, $CLR_HOME, '=' );
    for my $home (@homes) {
        my $sprite = $home->{occupied} ? $SPRITE{occupied} : $SPRITE{home};
        my $colour = $home->{occupied} ? $CLR_FROG         : $CLR_HOME;
        draw_sprite( $y, $home->{x}, $sprite, $colour );
    }
}

# River Area

sub draw_river {
    for my $row ( LOG1_ROW .. LOG4_ROW ) {
        my $y = row_y($row);
        draw_fill( $y,     $CLR_WATER, '~' );
        draw_fill( $y + 1, $CLR_WATER, '~' );
    }
}

# Safe Bank

sub draw_safe_bank {
    my $y = row_y(SAFE_ROW);
    draw_fill( $y,     $CLR_BANK, '.' );
    draw_fill( $y + 1, $CLR_BANK, '.' );
}

# Road Background

sub draw_road_lane {
    my ($row) = @_;
    my $y = row_y($row);
    #
    # asphalt
    #
    draw_fill( $y,     $CLR_TEXT, ' ' );
    draw_fill( $y + 1, $CLR_TEXT, ' ' );
    #
    # dashed lane marker
    #
    attron( COLOR_PAIR($CLR_TEXT) );
    for ( my $x = 0 ; $x < $PLAY_W ; $x += 6 ) {
        addstr( $y + 1, $x, '--' );
    }
    attroff( COLOR_PAIR($CLR_TEXT) );
}

sub draw_roads {
    draw_road_lane(ROAD1_ROW);
    draw_road_lane(ROAD2_ROW);
    draw_road_lane(ROAD3_ROW);
}

# Start Bank

sub draw_start_bank {
    my $y = row_y(START_ROW);
    draw_fill( $y,     $CLR_BANK, '.' );
    draw_fill( $y + 1, $CLR_BANK, '.' );
}

# Logs

sub draw_logs {
    attron( COLOR_PAIR($CLR_LOG) );
    for my $lane (@log_lanes) {
        my $y = row_y( $lane->{row} );
        for my $log ( @{ $lane->{logs} } ) {
            my $start = $log->{x};
            my $end   = $log->{x} + $log->{len} - 1;
            next
              if $end < 0;
            next
              if $start >= $PLAY_W;
            for my $x ( $start .. $end ) {
                next
                  if $x < 0;
                next
                  if $x >= $PLAY_W;
                addch( $y,     $x, ord('#') );
                addch( $y + 1, $x, ord('#') );
            }
        }
    }
    attroff( COLOR_PAIR($CLR_LOG) );
}

# Cars

sub draw_cars {
    for my $lane (@road_lanes) {
        my $y = row_y( $lane->{row} );
        for my $car ( @{ $lane->{vehicles} } ) {
            draw_sprite( $y, $car->{x}, $lane->{sprite}, $CLR_CAR );
        }
    }
}

# Frog

sub draw_frog {

    # death: show blinking at death location
    if ($death_flash) {
        return unless $blink_on;
        my $y = row_y($death_row);
        draw_sprite( $y, $death_x, $SPRITE{frog}, $CLR_FROG );
        return;
    }

    # normal gameplay render
    my $y = row_y( $frog{row} );
    draw_sprite( $y, $frog{x}, $SPRITE{frog}, $CLR_FROG );
}

# Full Render

sub render_frame {
    erase();
    draw_hud();
    draw_home_row();
    draw_river();
    draw_safe_bank();
    draw_roads();
    draw_start_bank();
    draw_logs();
    draw_cars();
    draw_frog();

    if ($level_up_flash) {
        draw_centered( 10, $CLR_HOME, "LEVEL COMPLETE!" );
        draw_centered( 12, $CLR_TEXT, "GET READY..." );

        if ( $level_deaths == 0 ) {
            draw_centered( 14, $CLR_TEXT, "PERFECT LEVEL BONUS!" );
        }
    }
    refresh();
}

# End Screens

sub draw_centered {
    my ( $row, $colour, $text ) = @_;
    my $x = int( ( $PLAY_W - length($text) ) / 2 );
    $x = 0 if $x < 0;
    draw_text( $row, $x, $colour, $text );
}

sub show_game_over {
    erase();
    draw_centered( 8,  $CLR_CAR,  "GAME OVER" );
    draw_centered( 10, $CLR_TEXT, sprintf( "FINAL SCORE: %d", $score ) );
    draw_centered( 12, $CLR_TEXT, "Press any key..." );
    refresh();
    nodelay(0);
    getch();
}

sub show_victory {
    erase();
    draw_centered( 8,  $CLR_FROG, "YOU WIN!" );
    draw_centered( 10, $CLR_TEXT, sprintf( "FINAL SCORE: %d", $score ) );
    draw_centered( 12, $CLR_TEXT, "All four homes filled" );
    draw_centered( 14, $CLR_TEXT, "Press any key..." );
    refresh();
    nodelay(0);
    getch();
}

# Frame Control

sub run_game {
    while ($running) {
        my $frame_start = time();
        update_game();
        last unless $running;
        render_frame();
        #
        # Simple frame limiter
        #
        my $elapsed = time() - $frame_start;
        my $target  = $FRAME_DELAY / 1_000_000;
        if ( $elapsed < $target ) {
            usleep( int( ( $target - $elapsed ) * 1_000_000 ) );
        }
    }
}

# Startup Screen

sub show_intro {
    erase();

    # draw_centered( 4,  $CLR_HOME, "FROGGER" );

    draw_centered( 2, $CLR_FROG, ".___                  " );
    draw_centered( 3, $CLR_FROG, "[__ ._. _  _  _  _ ._." );
    draw_centered( 4, $CLR_FROG, "|   [  (_)(_](_](/,[  " );
    draw_centered( 5, $CLR_FROG, "          ._|._|      " );

    draw_centered( 7,  $CLR_TEXT, "W A S D  - Move" );
    draw_centered( 9,  $CLR_TEXT, "Q - Quit" );
    draw_centered( 12, $CLR_TEXT, "Reach all 4 homes" );
    draw_centered( 14, $CLR_TEXT, "Avoid traffic" );
    draw_centered( 16, $CLR_TEXT, "Ride logs across river" );
    draw_centered( 18, $CLR_TEXT, "                          @..@  " );
    draw_centered( 19, $CLR_FROG, "                         (----) " );
    draw_centered( 20, $CLR_FROG, "Press any key to start  ( >__< )" );
    draw_centered( 21, $CLR_FROG, "                        ^^ ~~ ^^" );
    refresh();
    nodelay(0);
    getch();
    nodelay(1);
}

# Main Program

show_intro();
render_frame();
run_game();
erase();
if ($victory) {
    show_victory();
}
else {
    show_game_over();
}
endwin();
exit 0;
