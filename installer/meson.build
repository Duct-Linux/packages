project('duct-installer', 'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  default_options: ['c_std=gnu11', 'warning_level=2'],
)

# The versions ao/duct-3 packages. The development machine may well have
# something newer -- these constraints are what stop us compiling against an
# API the target cannot run.
gtk  = dependency('gtk4',        version: '>= 4.18')
adw  = dependency('libadwaita-1', version: '>= 1.7')

# The backend has no GTK in it on purpose: this whole process runs as root
# (there is no polkit), so the code that opens block devices should be
# reviewable without reading widget code.
backend = static_library('duct-backend',
  files(
    'src/backend/backend.c',
    'src/backend/disk.c',
    'src/backend/dryrun.c',
  ),
  dependencies: [dependency('glib-2.0'), dependency('gio-2.0')],
  include_directories: include_directories('src'),
)

executable('duct-installer',
  files(
    'src/main.c',
    'src/window.c',
    'src/page-welcome.c',
    'src/page-language.c',
    'src/page-keyboard.c',
    'src/page-disk.c',
    'src/page-timezone.c',
    'src/page-user.c',
    'src/page-summary.c',
    'src/page-progress.c',
    'src/page-done.c',
  ),
  dependencies: [gtk, adw],
  c_args: ['-DPACKAGE_VERSION="' + meson.project_version() + '"'],
  link_with: backend,
  include_directories: include_directories('src'),
  install: true,
)

# The installer without a display.
#
# Links the backend and nothing else -- no GTK. That is only possible because
# the backend was written with no GTK in it, and it is what makes exercising
# the installer inside QEMU cheap. It is a test harness, not unattended
# installation; see the comment at the top of src/cli/main.c.
install_cli = executable('duct-install-cli',
  files('src/cli/main.c'),
  dependencies: [dependency('glib-2.0'), dependency('gio-2.0')],
  link_with: backend,
  include_directories: include_directories('src'),
  install: true,
)

# The dangerous half, tested without a display. These check the properties the
# safety model claims -- the live medium is unplannable, every disk is
# describable in full, a dry run writes nothing.
backend_test = executable('backend-test',
  files('tests/backend-test.c'),
  dependencies: [dependency('glib-2.0'), dependency('gio-2.0')],
  link_with: backend,
  include_directories: include_directories('src'),
)
test('backend', backend_test)

# Shell syntax, including heredoc bodies a plain `bash -n` cannot see.
# See tests/check-shell-syntax.sh for why this is not paranoia.
test('shell-syntax', find_program('tests/check-shell-syntax.py'))

# The CLI's refusals, driven as a subprocess against the built binary.
#
# select_target() and load_answers() are static in a translation unit with a
# main(), so they cannot be linked into backend-test. Extracting them was the
# obvious alternative and is wrong for select_target: THE REFUSAL IS
# IMPLEMENTED BY NOT RETURNING -- it exits -- so extracting it would move the
# refusal into the caller and the test would then assert that a function
# reports a problem rather than that the program declines to act.
#
# The exit status IS the safety property, so the test drives the real binary.
test('cli', find_program('tests/cli-test.py'), args: [install_cli.full_path()])
