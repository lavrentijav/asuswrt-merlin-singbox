#!/bin/sh
# sbmerlin — WebUI page mounting.
#
# The page is exposed through the firmware's own addon slots (/www/user/userN.asp)
# and linked from the Tools menu by bind-mounting a patched menuTree.js. Nothing
# in /www is modified in place, so a firmware upgrade simply drops our changes.

SBM_MENU_SRC="/www/require/modules/menuTree.js"
SBM_MENU_TMP="/tmp/menuTree.js"
SBM_UI_TITLE="sing-box"

sbm_mount_ui() {
	_page="$SBM_WWW_DIR/sbmerlin.asp"
	[ -f "$_page" ] || { sbm_error "UI page missing: $_page"; return 1; }

	. /usr/sbin/helper.sh 2>/dev/null
	# Reuse the slot we already own. am_get_webui_page matches by file hash, so
	# after editing the page it would hand out a *new* slot and leave the old
	# copy behind — the browser would then keep showing the stale page.
	am_webui_page=$(am_settings_get sbm_page)
	if [ -z "$am_webui_page" ] || [ "$am_webui_page" = "none" ]; then
		am_get_webui_page "$_page"
	fi
	[ "$am_webui_page" = "none" ] && { sbm_error "no free WebUI slot (max 20 addon pages)"; return 1; }

	# Cache-bust the script: /www is served without revalidation.
	_stamp="$SBM_VERSION-$(date +%s)"
	sed "s|/ext/sbmerlin/sbmerlin.js|/ext/sbmerlin/sbmerlin.js?v=$_stamp|" "$_page" 		> "/www/user/$am_webui_page"
	echo "$SBM_UI_TITLE" > "/www/user/${am_webui_page%.asp}.title"
	am_settings_set sbm_page "$am_webui_page"

	mkdir -p "$SBM_EXT_DIR"
	# Assets the page pulls at runtime live next to the generated status file.
	cp -f "$SBM_WWW_DIR/sbmerlin.js" "$SBM_EXT_DIR/sbmerlin.js" 2>/dev/null

	sbm_drop_stale_slots "$am_webui_page"
	sbm_menu_add "$am_webui_page"
	sbm_info "UI mounted at /$am_webui_page"
	return 0
}

# Older versions of this addon (or a hash-based slot hand-out) can leave a second
# copy of the page behind, which shows up as a duplicate, stale Addons entry.
sbm_drop_stale_slots() {
	_keep="$1"
	for _t in /www/user/user*.title; do
		[ -f "$_t" ] || continue
		[ "$(cat "$_t" 2>/dev/null)" = "$SBM_UI_TITLE" ] || continue
		_slot="$(basename "$_t" .title).asp"
		[ "$_slot" = "$_keep" ] && continue
		rm -f "/www/user/$_slot" "$_t"
		sbm_info "removed stale UI copy /$_slot"
	done
	return 0
}

sbm_unmount_ui() {
	. /usr/sbin/helper.sh 2>/dev/null
	_page=$(am_settings_get sbm_page)
	if [ -n "$_page" ]; then
		rm -f "/www/user/$_page" "/www/user/${_page%.asp}.title"
		am_settings_set sbm_page ""
	fi
	sbm_menu_remove
	rm -rf "$SBM_EXT_DIR"
	sbm_info "UI unmounted"
	return 0
}

# Add our page to the Tools menu. The current menuTree.js may already be a
# bind-mounted copy carrying other addons' entries, so patch what is visible now.
sbm_menu_add() {
	_slot="$1"
	grep -q "sbmerlin" "$SBM_MENU_SRC" 2>/dev/null && sbm_menu_remove
	cp -f "$SBM_MENU_SRC" "$SBM_MENU_TMP.new" || return 1
	# Insert right before the Tools menu's terminating __INHERIT__ entry.
	awk -v slot="$_slot" -v title="$SBM_UI_TITLE" '
		/index: "menu_Tools"/ { in_tools = 1 }
		in_tools && /tabName: "__INHERIT__"/ && !done {
			printf "{url: \"%s\", tabName: \"%s\"}, /*sbmerlin*/\n", slot, title
			done = 1
		}
		{ print }
	' "$SBM_MENU_TMP.new" > "$SBM_MENU_TMP" || return 1
	rm -f "$SBM_MENU_TMP.new"
	umount "$SBM_MENU_SRC" 2>/dev/null
	mount -o bind "$SBM_MENU_TMP" "$SBM_MENU_SRC"
}

sbm_menu_remove() {
	grep -q "sbmerlin" "$SBM_MENU_SRC" 2>/dev/null || return 0
	grep -v "/\*sbmerlin\*/" "$SBM_MENU_SRC" > "$SBM_MENU_TMP.clean" 2>/dev/null || return 1
	umount "$SBM_MENU_SRC" 2>/dev/null
	# Re-bind only if other addons still need the patched copy.
	if grep -q "tabName" "$SBM_MENU_TMP.clean" && ! cmp -s "$SBM_MENU_TMP.clean" "$SBM_MENU_SRC"; then
		mv -f "$SBM_MENU_TMP.clean" "$SBM_MENU_TMP"
		mount -o bind "$SBM_MENU_TMP" "$SBM_MENU_SRC"
	else
		rm -f "$SBM_MENU_TMP.clean"
	fi
	return 0
}
