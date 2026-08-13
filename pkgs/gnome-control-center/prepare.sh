#!/bin/sh
set -eu
. "$(dirname "$0")/../_scripts/common.sh"

# The printers panel has an unconditional Samba client dependency. Samba is
# not yet part of Duct, while the remaining Settings panels are useful on the
# live image, so omit this one panel from both compilation and registration.
sed -i "/^[[:space:]]*'printers',[[:space:]]*$/d" "$SRC_PATH/panels/meson.build"
sed -i '/^[[:space:]]*"printers",[[:space:]]*$/d' "$SRC_PATH/shell/cc-panel-list.c"

# The System panel requires udisks2. Its storage stack is not packaged yet;
# keep the rest of Settings usable while that independent closure is finished.
sed -i "/^[[:space:]]*'system',[[:space:]]*$/d" "$SRC_PATH/panels/meson.build"
sed -i '/^[[:space:]]*"system",[[:space:]]*$/d' "$SRC_PATH/shell/cc-panel-list.c"
