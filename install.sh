#!/usr/bin/env bash

set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$ROOT/tools/macos"
LIB="$TOOLS/lib"
KEY_SYS="$ROOT/firmware/keys/iPhone5,2-10B350.json"
KEY_BOOT="$ROOT/firmware/keys/iPhone5,3-11A470a.json"
IPSW_SYS="${FIVE_C_SIX_IPSW:-}"
RAMDISK_SRC="$ROOT/firmware/ssh-ramdisk/11A470a"
SSH_RES="$ROOT/resources/ssh"
FIXKEYBAG="$ROOT/resources/fixkeybag/fixkeybag"
CONFIG="$ROOT/config"
TETHER="$ROOT/firmware/tether-boot/10B350"
WORK="$ROOT/work"
SSH_PORT=6414
SSH_HOST="root@127.0.0.1"
DEVICE_CONFIG_STAGE="/mnt2/.5c-six-config"
IPROXY_PID=

SSH_OPTIONS=(
    -oHostKeyAlgorithms=+ssh-dss
    -oPubkeyAcceptedAlgorithms=+ssh-rsa
    -oKexAlgorithms=+diffie-hellman-group1-sha1
    -oCiphers=+aes128-cbc,3des-cbc
    -oMACs=+hmac-sha1
    -oStrictHostKeyChecking=no
    -oUserKnownHostsFile=/dev/null
    -oLogLevel=ERROR
    -oConnectTimeout=5
)

export DYLD_LIBRARY_PATH="$LIB${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

log() { printf '[5c-Six] %s\n' "$*"; }
warn() { printf '[5c-Six WARNING] %s\n' "$*" >&2; }
die() { printf '[5c-Six ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n $IPROXY_PID ]]; then
        kill "$IPROXY_PID" 2>/dev/null || true
        wait "$IPROXY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

need_file() {
    [[ -s $1 ]] || die "Required project file is missing: $1"
}

ssh_device() {
    "$TOOLS/sshpass" -p alpine /usr/bin/ssh "${SSH_OPTIONS[@]}" -p "$SSH_PORT" "$SSH_HOST" "$@"
}

scp_device() {
    local scp_usage
    scp_usage="$(/usr/bin/scp -h 2>&1 || true)"
    if [[ $scp_usage =~ \[-[[:alnum:]]*O[[:alnum:]]*\] ]]; then
        "$TOOLS/sshpass" -p alpine /usr/bin/scp -O "${SSH_OPTIONS[@]}" -P "$SSH_PORT" "$@"
    else
        "$TOOLS/sshpass" -p alpine /usr/bin/scp "${SSH_OPTIONS[@]}" -P "$SSH_PORT" "$@"
    fi
}

ssh_device_tty_pipe() {
    local input="$1" remote="$2"
    printf '%s' "$input" | "$TOOLS/sshpass" -p alpine /usr/bin/ssh -tt \
        "${SSH_OPTIONS[@]}" -p "$SSH_PORT" "$SSH_HOST" "$remote"
}

start_proxy() {
    if [[ -n $IPROXY_PID ]] && kill -0 "$IPROXY_PID" 2>/dev/null; then
        return
    fi
    "$TOOLS/iproxy" "$SSH_PORT" 22 -s 127.0.0.1 > "$WORK/iproxy.log" 2>&1 &
    IPROXY_PID=$!
    sleep 1
}

get_key() {
    local json="$1" image="$2" field="$3"
    "$TOOLS/jq" -er --arg image "$image" --arg field "$field" \
        '.keys[] | select(.image == $image) | .[$field]' "$json"
}

validate_ipsw() {
    local candidate="$1" build
    [[ -f "$candidate" ]] || { warn "IPSW file does not exist: $candidate"; return 1; }
    build="$(unzip -p "$candidate" BuildManifest.plist 2>/dev/null | \
        /usr/bin/plutil -extract ProductBuildVersion raw -o - - 2>/dev/null)" || {
        warn "Cannot read BuildManifest.plist from $candidate"
        return 1
    }
    [[ $build == "10B350" ]] || {
        warn "IPSW build is '$build'; this project requires 10B350"
        return 1
    }
    unzip -p "$candidate" BuildManifest.plist 2>/dev/null | \
        /usr/bin/plutil -convert xml1 -o - - 2>/dev/null | \
        /usr/bin/perl -0777 -ne \
            'exit !(/<key>SupportedProductTypes<\/key>\s*<array>(?:(?!<\/array>).)*<string>iPhone5,2<\/string>/s)' || {
        warn "IPSW is not for iPhone5,2"
        return 1
    }
}

choose_local_ipsw() {
    local selected
    selected="$(/usr/bin/osascript -e \
        'POSIX path of (choose file with prompt "Select the iPhone5,2 iOS 6.1.4 (10B350) IPSW")' \
        2>/dev/null)" || die "IPSW selection was cancelled"
    [[ -f "$selected" ]] || die "Selected IPSW file does not exist: $selected"
    validate_ipsw "$selected" || die "Select an iPhone5,2 iOS 6.1.4 (10B350) IPSW"
    IPSW_SYS="$selected"
}

select_option() {
    local -a options=("$@")
    local count=${#options[@]}
    local selected=0
    local index key old_int_trap

    for ((index = 0; index < count; index++)); do
        printf '\n'
    done
    printf '\033[%dA\033[?25l' "$count"
    old_int_trap="$(trap -p INT)"
    trap 'printf "\033[?25h\n"; exit 130' INT

    while true; do
        for ((index = 0; index < count; index++)); do
            printf '\r\033[2K'
            if (( index == selected )); then
                printf ' ->\033[7m %s \033[27m\n' "${options[$index]}"
            else
                printf '    %s\n' "${options[$index]}"
            fi
        done
        printf '\033[%dA' "$count"

        key=
        IFS= read -r -s -n 1 key || key=
        case $key in
            $'\033' )
                IFS= read -r -s -n 2 key || key=
                case $key in
                    '[A' ) ((selected > 0)) && ((selected--));;
                    '[B' ) ((selected < count - 1)) && ((selected++));;
                esac
                ;;
            '' ) break;;
        esac
    done

    printf '\033[%dB\033[?25h\n' "$count"
    if [[ -n $old_int_trap ]]; then
        eval "$old_int_trap"
    else
        trap - INT
    fi
    return "$selected"
}

download_system_ipsw() {
    local api_url="https://api.ipsw.me/v4/device/iPhone5,2?type=ipsw"
    local metadata ipsw_url expected_sha expected_size destination partial actual_size actual_sha
    destination="$WORK/iPhone5,2_6.1.4_10B350_Restore.ipsw"
    partial="$destination.part"

    log "Looking up the iPhone5,2 10B350 IPSW download link"
    metadata="$(/usr/bin/curl --fail --silent --show-error --location \
        --connect-timeout 20 --max-time 60 "$api_url")" || \
        die "Could not query ipsw.me; check the network and try again"
    metadata="$(printf '%s' "$metadata" | "$TOOLS/jq" -er \
        '.firmwares[] | select(.identifier == "iPhone5,2" and .buildid == "10B350") | [.url, .sha256sum, (.filesize | tostring)] | @tsv')" || {
        die "ipsw.me did not return the expected iPhone5,2 10B350 firmware"
    }
    IFS=$'\t' read -r ipsw_url expected_sha expected_size <<< "$metadata"
    [[ $ipsw_url =~ ^https://([[:alnum:]-]+\.)*(apple\.com|cdn-apple\.com)/ &&
       $expected_sha =~ ^[[:xdigit:]]{64}$ && $expected_size =~ ^[0-9]+$ ]] || {
        die "ipsw.me returned invalid download metadata"
    }

    if [[ -s $destination ]]; then
        actual_sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
        if [[ $actual_sha == "$expected_sha" ]] && validate_ipsw "$destination"; then
            printf '%s\n' "$expected_sha" > "$destination.sha256"
            IPSW_SYS="$destination"
            log "Using cached downloaded IPSW: $IPSW_SYS"
            return
        fi
        warn "Cached downloaded IPSW failed verification; downloading it again"
        rm -f "$destination"
    fi

    if [[ -s $partial ]]; then
        actual_size="$(wc -c < "$partial" | tr -d '[:space:]')"
        if (( actual_size > expected_size )); then
            warn "Discarding oversized partial IPSW download"
            rm -f "$partial"
        elif (( actual_size == expected_size )); then
            actual_sha="$(shasum -a 256 "$partial" | awk '{print $1}')"
            if [[ $actual_sha == "$expected_sha" ]]; then
                mv "$partial" "$destination" || die "Could not save the downloaded IPSW"
                printf '%s\n' "$expected_sha" > "$destination.sha256"
                IPSW_SYS="$destination"
                log "Verified downloaded IPSW: $IPSW_SYS"
                return
            fi
            warn "Discarding completed IPSW download with a SHA-256 mismatch"
            rm -f "$partial"
        fi
    fi

    log "Downloading iPhone5,2 iOS 6.1.4 IPSW from Apple (about 1 GB)"
    /usr/bin/curl --fail --location --show-error --retry 3 --connect-timeout 30 \
        --continue-at - --output "$partial" "$ipsw_url" || \
        die "IPSW download failed; rerun the command to resume from $partial"
    actual_size="$(wc -c < "$partial" | tr -d '[:space:]')"
    [[ $actual_size == "$expected_size" ]] || \
        die "Downloaded IPSW size mismatch (expected $expected_size bytes, got $actual_size); partial file kept at $partial"
    actual_sha="$(shasum -a 256 "$partial" | awk '{print $1}')"
    [[ $actual_sha == "$expected_sha" ]] || {
        rm -f "$partial"
        die "Downloaded IPSW SHA-256 mismatch; removed the invalid download"
    }
    mv "$partial" "$destination" || die "Could not save the downloaded IPSW"
    validate_ipsw "$destination" || die "Downloaded IPSW failed BuildManifest validation"
    printf '%s\n' "$expected_sha" > "$destination.sha256"
    IPSW_SYS="$destination"
    log "Verified downloaded IPSW: $IPSW_SYS"
}

choose_ipsw_source() {
    local selection
    warn "No compatible iPhone5,2 iOS 6.1.4 (10B350) IPSW was found."
    log "Select an option:"
    select_option "Select a local IPSW" "Download IPSW from Apple"
    selection=$?
    case $selection in
        0) choose_local_ipsw;;
        1) download_system_ipsw;;
    esac
}

select_system_ipsw() {
    local candidate choice i cached_ipsw
    local -a valid_ipsws=()

    if [[ -n $IPSW_SYS ]]; then
        [[ $IPSW_SYS == /* ]] || IPSW_SYS="$PWD/$IPSW_SYS"
        validate_ipsw "$IPSW_SYS" || die "FIVE_C_SIX_IPSW must point to an iPhone5,2 10B350 IPSW"
        log "Using explicitly selected IPSW: $IPSW_SYS"
        return
    fi

    for candidate in "$ROOT"/*.[iI][pP][sS][wW]; do
        [[ -f "$candidate" ]] || continue
        if validate_ipsw "$candidate"; then
            valid_ipsws+=("$candidate")
        else
            warn "Ignoring incompatible IPSW in project root: $candidate"
        fi
    done

    case ${#valid_ipsws[@]} in
        0)
            cached_ipsw="$WORK/iPhone5,2_6.1.4_10B350_Restore.ipsw"
            if [[ -s $cached_ipsw && -s "$cached_ipsw.sha256" ]] &&
               validate_ipsw "$cached_ipsw" &&
               [[ $(shasum -a 256 "$cached_ipsw" | awk '{print $1}') == "$(<"$cached_ipsw.sha256")" ]]; then
                IPSW_SYS="$cached_ipsw"
                log "Using cached IPSW: $IPSW_SYS"
            else
                choose_ipsw_source
            fi
            ;;
        1)
            IPSW_SYS="${valid_ipsws[0]}"
            log "Auto-selected project-root IPSW: $IPSW_SYS"
            ;;
        *)
            log "Multiple compatible IPSWs were found in the project root:"
            for ((i = 0; i < ${#valid_ipsws[@]}; i++)); do
                printf '  %d) %s\n' "$((i + 1))" "${valid_ipsws[$i]}"
            done
            printf '  0) Choose another local IPSW\n'
            read -r -p "Select an IPSW [0-${#valid_ipsws[@]}]: " choice
            if [[ $choice == 0 ]]; then
                choose_local_ipsw
            elif [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#valid_ipsws[@]} )); then
                IPSW_SYS="${valid_ipsws[$((choice - 1))]}"
            else
                die "Invalid IPSW selection"
            fi
            ;;
    esac
    log "Using IPSW: $IPSW_SYS"
}

check_host() {
    [[ $(uname -s) == "Darwin" ]] || die "This standalone bundle currently supports macOS only."
    [[ $(uname -m) == "x86_64" ]] || die "This bundle includes the Intel ipwnder32 binary; run it on an Intel Mac."
    [[ -x /usr/bin/ssh && -x /usr/bin/scp && -x /usr/bin/sudo ]] || die "macOS ssh/scp/sudo tools are required"
    command -v unzip >/dev/null || die "unzip is required"
    command -v hdiutil >/dev/null || die "hdiutil is required"
    [[ -x /usr/bin/curl ]] || die "macOS curl is required"
    [[ -x /usr/bin/plutil && -x /usr/bin/osascript && -x /usr/bin/perl ]] || die "macOS plutil, osascript, and perl are required"
    local file
    for file in \
        "$TOOLS/xpwntool" "$TOOLS/iBoot32Patcher" "$TOOLS/img3maker" \
        "$TOOLS/dmg" "$TOOLS/hfsplus" "$TOOLS/irecovery" "$TOOLS/iproxy" \
        "$TOOLS/sshpass" "$TOOLS/ipwnder32" "$TOOLS/primepwn" "$TOOLS/jq" "$TOOLS/gtar" \
        "$ROOT/firmware/pwned/pwnediBSS.dfu" \
        "$KEY_SYS" "$KEY_BOOT" "$FIXKEYBAG" \
        "$SSH_RES/ssh.tar.gz" "$SSH_RES/sbplist.tar" \
        "$RAMDISK_SRC/048-8814-006.dmg" \
        "$RAMDISK_SRC/DeviceTree.n48ap.img3" \
        "$RAMDISK_SRC/iBEC.n48ap.RELEASE.dfu" \
        "$RAMDISK_SRC/iBSS.n48ap.RELEASE.dfu" \
        "$RAMDISK_SRC/kernelcache.release.n48" \
        "$CONFIG/fstab" "$CONFIG/launchd.conf" "$CONFIG/kernelcache-10B350.tsv"; do
        need_file "$file"
    done
    local dylib
    for dylib in libirecovery-1.0.5.dylib libimobiledevice-glue-1.0.0.dylib libplist-2.0.12.dylib libusbmuxd-2.0.7.dylib; do
        need_file "$LIB/$dylib"
    done
    [[ $(shasum -a 256 "$FIXKEYBAG" | awk '{print $1}') == \
        "e3073e4da23d0343ca0a74f890df5519501431b60e5dc5d065fbf8f090a827f3" ]] || \
        die "fixkeybag SHA-256 mismatch"
}

decode_component() {
    local json="$1" image="$2" source="$3" dest="$4"
    local iv key
    iv="$(get_key "$json" "$image" iv)" || die "No IV key for $image"
    key="$(get_key "$json" "$image" key)" || die "No AES key for $image"
    "$TOOLS/xpwntool" "$source" "$dest" -iv "$iv" -k "$key" -decrypt || \
        die "Could not decrypt $image from $source"
}

prepare_rootfs() {
    local root_name root_key mountpoint="$WORK/rootfs-mount"
    need_file "$IPSW_SYS"
    root_name="$(get_key "$KEY_SYS" RootFS filename)" || die "No RootFS filename in system keys"
    root_key="$(get_key "$KEY_SYS" RootFS key)" || die "No RootFS key in system keys"
    mkdir -p "$mountpoint"

    if [[ -s "$WORK/fw.tar" ]]; then
        if "$TOOLS/gtar" -tf "$WORK/fw.tar" >/dev/null 2>&1; then
            log "Reusing existing RootFS archive: $WORK/fw.tar"
            return
        fi
        warn "Existing fw.tar is incomplete; rebuilding it"
        rm -f "$WORK/fw.tar"
    fi
    log "Extracting encrypted RootFS from 10B350"
    unzip -p "$IPSW_SYS" "$root_name" > "$WORK/rootfs.encrypted.dmg" || die "Cannot extract $root_name"
    "$TOOLS/dmg" extract "$WORK/rootfs.encrypted.dmg" "$WORK/rootfs.decrypted.dmg" -k "$root_key" || \
        die "Cannot decrypt iOS 6 RootFS"
    "$TOOLS/dmg" build "$WORK/rootfs.decrypted.dmg" "$WORK/rootfs.udzo.dmg" || \
        die "Cannot convert RootFS to UDZO"
    hdiutil attach -quiet -nobrowse -mountpoint "$mountpoint" "$WORK/rootfs.udzo.dmg" || \
        die "Cannot mount decrypted RootFS"
    if ! sudo diskutil enableOwnership "$mountpoint"; then
        hdiutil detach "$mountpoint" -quiet || true
        die "Could not enable RootFS ownership"
    fi
    if ! sudo "$TOOLS/gtar" --numeric-owner -cf "$WORK/fw.tar" -C "$mountpoint" .; then
        hdiutil detach "$mountpoint" -quiet || true
        die "Could not create ownership-preserving RootFS tar"
    fi
    hdiutil detach "$mountpoint" -quiet || warn "Could not detach RootFS image automatically"
    need_file "$WORK/fw.tar"
    log "RootFS archive ready: $WORK/fw.tar"
}

build_tether_components() {
    local cache_build="$TETHER/boot-build"
    local comp name iv key dt_name kc_name offset expected replacement actual
    mkdir -p "$TETHER"
    if [[ -s "$TETHER/iBSS.img3" && -s "$TETHER/iBEC.img3" &&
          -s "$TETHER/DeviceTree.img3" && -s "$TETHER/kernelcache.img3" && -s "$cache_build" ]] &&
       [[ $(<"$cache_build") == "11A470a-amfi-debug" ]] &&
       [[ "$(strings "$TETHER/iBEC.img3" | perl -ne 'if (index($_, "amfi_get_out_of_my_way=1") >= 0) {$ok=1} END {print $ok ? "yes" : "no"}')" == "yes" ]]; then
        log "Using verified 11A470a AMFI-debug boot components"
        return
    fi

    [[ -n $IPSW_SYS ]] || select_system_ipsw
    need_file "$IPSW_SYS"
    log "Building iOS 7.0 11A470a iBSS/iBEC"
    for comp in iBSS iBEC; do
        name="$(get_key "$KEY_BOOT" "$comp" filename)" || die "No $comp filename in 11A470a keys"
        iv="$(get_key "$KEY_BOOT" "$comp" iv)" || die "No $comp IV in 11A470a keys"
        key="$(get_key "$KEY_BOOT" "$comp" key)" || die "No $comp key in 11A470a keys"
        cp "$RAMDISK_SRC/$name" "$WORK/$name"
        "$TOOLS/xpwntool" "$WORK/$name" "$WORK/$comp.raw" -iv "$iv" -k "$key" || \
            die "Could not decrypt $comp"
        if [[ $comp == "iBSS" ]]; then
            "$TOOLS/iBoot32Patcher" "$WORK/$comp.raw" "$WORK/$comp.patched" --rsa
            actual="$(xxd -p -l 4 -s $((16#6aec)) "$WORK/$comp.patched" 2>/dev/null | tr -d '\n')"
            [[ -s "$WORK/$comp.patched" && $actual == "00201860" ]] || die "iBSS RSA patch verification failed"
            "$TOOLS/img3maker" -f "$WORK/$comp.patched" -t ibss -o "$TETHER/iBSS.img3" || \
                die "Could not package iBSS"
        else
            "$TOOLS/iBoot32Patcher" "$WORK/$comp.raw" "$WORK/$comp.patched" --rsa --debug \
                -b "-v amfi=0xff amfi_get_out_of_my_way=1 cs_enforcement_disable=1 pio-error=0"
            actual="$(xxd -p -l 4 -s $((16#1b1a4)) "$WORK/$comp.patched" 2>/dev/null | tr -d '\n')"
            [[ -s "$WORK/$comp.patched" && $actual == "00201860" ]] || die "iBEC RSA patch verification failed"
            strings "$WORK/$comp.patched" | perl -ne \
                'if (index($_, "-v amfi=0xff amfi_get_out_of_my_way=1 cs_enforcement_disable=1 pio-error=0") >= 0) {$ok=1} END {exit !$ok}' || \
                die "iBEC AMFI boot-args verification failed"
            "$TOOLS/img3maker" -f "$WORK/$comp.patched" -t ibec -o "$TETHER/iBEC.img3" || \
                die "Could not package iBEC"
        fi
    done

    log "Decrypting iPhone5,2 10B350 DeviceTree and kernelcache"
    dt_name="$(get_key "$KEY_SYS" DeviceTree filename)" || die "No DeviceTree filename in 10B350 keys"
    unzip -p "$IPSW_SYS" "Firmware/all_flash/all_flash.n42ap.production/$dt_name" > "$WORK/$dt_name" || \
        die "Cannot extract 10B350 DeviceTree"
    decode_component "$KEY_SYS" DeviceTree "$WORK/$dt_name" "$TETHER/DeviceTree.img3"

    kc_name="$(get_key "$KEY_SYS" Kernelcache filename)" || die "No kernelcache filename in 10B350 keys"
    unzip -p "$IPSW_SYS" "$kc_name" > "$WORK/$kc_name" || die "Cannot extract 10B350 kernelcache"
    decode_component "$KEY_SYS" Kernelcache "$WORK/$kc_name" "$WORK/kernelcache.dec"
    iv="$(get_key "$KEY_SYS" Kernelcache iv)"
    key="$(get_key "$KEY_SYS" Kernelcache key)"
    "$TOOLS/xpwntool" "$WORK/$kc_name" "$WORK/kernelcache.raw" -iv "$iv" -k "$key" || \
        die "Could not decompress 10B350 kernelcache"
    while read -r offset expected replacement _; do
        [[ -z $offset || $offset == \#* ]] && continue
        actual="$(xxd -p -l 4 -s "$((16#$offset))" "$WORK/kernelcache.raw" | tr -d '\n')"
        [[ $actual == "$expected" ]] || die "Kernel patch signature mismatch at 0x$offset"
        printf '%s' "$replacement" | xxd -r -p | dd of="$WORK/kernelcache.raw" bs=1 seek="$((16#$offset))" conv=notrunc 2>/dev/null
        actual="$(xxd -p -l 4 -s "$((16#$offset))" "$WORK/kernelcache.raw" | tr -d '\n')"
        [[ $actual == "$replacement" ]] || die "Kernel patch write failed at 0x$offset"
    done < "$CONFIG/kernelcache-10B350.tsv"
    "$TOOLS/xpwntool" "$WORK/kernelcache.raw" "$TETHER/kernelcache.img3" -t "$WORK/kernelcache.dec" || \
        die "Could not repack patched 10B350 kernelcache"
    printf '11A470a-amfi-debug\n' > "$cache_build"
}

check_device() {
    local info product
    info="$("$TOOLS/irecovery" -q 2>/dev/null)" || die "No device detected by irecovery"
    product="$(printf '%s\n' "$info" | awk -F': ' '/PRODUCT/ {print $2; exit}')"
    [[ $product == "iPhone5,3" || $product == "n48ap" || $product == "n48" ]] || \
        die "Connected DFU device is '$product', expected iPhone5,3/n48"
    printf '%s\n' "$info"
}

enter_pwned_ibss() {
    local info pwn_status
    info="$(check_device)"
    [[ $info == *"MODE: DFU"* ]] || die "Put iPhone5,3 in DFU mode first. Detected mode: $(printf '%s\n' "$info" | perl -ne 'print if /MODE/')"
    log "Pwnning DFU with ipwnder32"
    "$TOOLS/ipwnder32" -p --noibss
    pwn_status=$?
    info="$("$TOOLS/irecovery" -q 2>/dev/null || true)"
    if [[ $info != *"PWND"* && $pwn_status != 0 ]]; then
        die "ipwnder32 failed to pwn DFU; device status: $info"
    fi
    [[ $info == *"PWND"* || $info == *"MODE: DFU"* ]] || die "Device left DFU after bootrom exploit"
    log "Sending the A6 pwned-iBSS stage with primepwn"
    "$TOOLS/primepwn" "$ROOT/firmware/pwned/pwnediBSS.dfu" || \
        die "primepwn could not enter pwned iBSS"
    sleep 1
    info="$("$TOOLS/irecovery" -q 2>&1 || true)"
    [[ -n $info && $info != ERROR* ]] || die "Device did not accept the pwned-iBSS stage"
}

build_ssh_ramdisk() {
    local work="$WORK/ramdisk"
    local comp name iv key
    local cache_stamp="$WORK/ramdisk/build-stamp"
    mkdir -p "$work"
    if [[ -s "$work/Ramdisk.dmg" && -s "$work/iBEC.send" &&
          -s $cache_stamp && $(<"$cache_stamp") == "11A470a-sshrd-v1" ]]; then
        log "Reusing cached SSH ramdisk images"
        return
    fi
    for comp in iBEC DeviceTree Kernelcache RestoreRamdisk; do
        name="$(get_key "$KEY_BOOT" "$comp" filename)" || die "No $comp filename in 11A470a keys"
        cp "$RAMDISK_SRC/$name" "$work/$name"
        decode_component "$KEY_BOOT" "$comp" "$work/$name" "$work/$comp.dec"
    done
    "$TOOLS/xpwntool" "$work/RestoreRamdisk.dec" "$work/Ramdisk.raw" || die "Cannot unpack SSH ramdisk"
    "$TOOLS/hfsplus" "$work/Ramdisk.raw" grow 32000000 || die "Cannot grow SSH ramdisk"
    "$TOOLS/hfsplus" "$work/Ramdisk.raw" untar "$SSH_RES/sbplist.tar" || die "Cannot add ramdisk launchd plist"
    gzip -dc "$SSH_RES/ssh.tar.gz" > "$work/ssh.tar" || die "Cannot unpack bundled SSH tools"
    "$TOOLS/hfsplus" "$work/Ramdisk.raw" untar "$work/ssh.tar" || die "Cannot add SSH to ramdisk"
    "$TOOLS/hfsplus" "$work/Ramdisk.raw" mv sbin/reboot sbin/reboot_bak
    "$TOOLS/hfsplus" "$work/Ramdisk.raw" mv sbin/halt sbin/halt_bak
    "$TOOLS/xpwntool" "$work/Ramdisk.raw" "$work/Ramdisk.dmg" -t "$work/RestoreRamdisk.dec" || \
        die "Cannot repack SSH ramdisk"

    "$TOOLS/xpwntool" "$work/iBEC.dec" "$work/iBEC.raw" || die "Cannot prepare SSH ramdisk iBEC"
    "$TOOLS/iBoot32Patcher" "$work/iBEC.raw" "$work/iBEC.patched" --rsa --debug \
        -b "rd=md0 -v amfi=0xff amfi_get_out_of_my_way=1 cs_enforcement_disable=1 pio-error=0"
    [[ -s "$work/iBEC.patched" ]] || die "Cannot patch SSH ramdisk iBEC"
    "$TOOLS/xpwntool" "$work/iBEC.patched" "$work/iBEC.send" -t "$work/iBEC.dec" || \
        die "Cannot package SSH ramdisk iBEC"
    printf '11A470a-sshrd-v1\n' > "$cache_stamp"
}

boot_ssh_ramdisk() {
    local work="$WORK/ramdisk"
    build_ssh_ramdisk
    enter_pwned_ibss
    log "Sending SSH ramdisk iBEC"
    "$TOOLS/irecovery" -f "$work/iBEC.send" || die "Failed to send SSH ramdisk iBEC"
    wait_recovery
    log "Sending and booting SSH ramdisk"
    "$TOOLS/irecovery" -f "$work/Ramdisk.dmg" || die "Failed to send SSH ramdisk image"
    "$TOOLS/irecovery" -c "getenv ramdisk-delay" >/dev/null 2>&1 || true
    "$TOOLS/irecovery" -c ramdisk || die "Failed to start SSH ramdisk"
    "$TOOLS/irecovery" -f "$work/DeviceTree.dec" || die "Failed to send SSH ramdisk DeviceTree"
    "$TOOLS/irecovery" -c devicetree || die "Failed to execute SSH ramdisk DeviceTree"
    "$TOOLS/irecovery" -f "$work/Kernelcache.dec" || die "Failed to send SSH ramdisk kernelcache"
    "$TOOLS/irecovery" -c bootx || die "Failed to boot SSH ramdisk"
    wait_ssh
}

wait_recovery() {
    local tries=0 info
    while (( tries < 30 )); do
        info="$("$TOOLS/irecovery" -q 2>/dev/null || true)"
        [[ $info == *"MODE: Recovery"* ]] && return 0
        ((tries += 1))
        sleep 1
    done
    die "Device did not enter Recovery after iBEC"
}

wait_ssh() {
    local tries=0
    log "Starting USB SSH proxy and waiting for the ramdisk"
    "$TOOLS/iproxy" "$SSH_PORT" 22 -s 127.0.0.1 > "$WORK/iproxy.log" 2>&1 &
    IPROXY_PID=$!
    while (( tries < 90 )); do
        if ssh_device "echo ready" >/dev/null 2>&1; then
            log "SSH ramdisk is ready"
            return 0
        fi
        kill -0 "$IPROXY_PID" 2>/dev/null || die "iproxy exited; inspect $WORK/iproxy.log"
        ((tries += 1))
        sleep 2
    done
    die "SSH ramdisk did not start or accept root/alpine"
}

install_rootfs() {
    local last_sector partition_input answer
    prepare_rootfs
    boot_ssh_ramdisk
    warn "This destroys the current partition table and device data."
    read -r -p "Press Enter to repartition and install iOS 6.1.4 (Ctrl-C to cancel): " answer
    [[ -z $answer ]] || die "Install cancelled; no partitions changed"
    last_sector="$(ssh_device 'gptfdisk -l /dev/rdisk0s1' | awk 'tolower($0) ~ /last usable sector is/ {print $NF; exit}')"
    [[ $last_sector =~ ^[0-9]+$ ]] || die "Could not read last usable GPT sector"
    last_sector=$((last_sector - 4))
    (( last_sector > 524294 )) || die "Disk geometry is too small"
    partition_input="$(printf 'd\r1\rd\r2\rn\r1\r\r524294\r\rn\r\r%s\r\rc\r1\rSystem\rc\r2\rData\rw\ry\r\n' "$last_sector")"
    log "Writing System/Data GPT. Keep the USB cable connected."
    ssh_device_tty_pipe "$partition_input" "gptfdisk /dev/rdisk0s1" || \
        die "GPT partition write failed. Do not format; boot SSH ramdisk and inspect GPT first."
    ssh_device "/sbin/newfs_hfs -s -v System -J -b 4096 -n a=4096,c=4096,e=4096 /dev/disk0s1s1 && /sbin/newfs_hfs -s -v Data -J -P -b 4096 -n a=4096,c=4096,e=4096 /dev/disk0s1s2 && mkdir -p /mnt1 /mnt2 && mount_hfs /dev/disk0s1s1 /mnt1 && mount_hfs /dev/disk0s1s2 /mnt2" || \
        die "Could not format or mount System/Data"
    log "Streaming RootFS to the device; this takes several minutes"
    cat "$WORK/fw.tar" | ssh_device "cd /mnt1 && /bin/tar xpf -" \
        2> >(perl -ne 'print unless m{^/bin/tar: .*time stamp \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} is \d+(?:\.\d+)? s in the future\s*$}') || \
        die "RootFS transfer/extraction failed"
    ssh_device "mv /mnt1/private/var/* /mnt2 && mkdir -p /mnt2/keybags && chown 0:0 /mnt2/keybags && chmod 755 /mnt2/keybags" || \
        die "Could not place /private/var or prepare keybags"
    ssh_device "mkdir -p $DEVICE_CONFIG_STAGE" || die "Could not prepare the temporary configuration directory"
    scp_device "$CONFIG/fstab" "$CONFIG/launchd.conf" "$FIXKEYBAG" "$SSH_HOST:$DEVICE_CONFIG_STAGE/" || \
        die "Could not send configuration files"
    ssh_device "cp $DEVICE_CONFIG_STAGE/fstab /mnt1/private/etc/fstab && cp $DEVICE_CONFIG_STAGE/launchd.conf /mnt1/private/etc/launchd.conf && cp $DEVICE_CONFIG_STAGE/fixkeybag /mnt1/fixkeybag && chown 0:0 /mnt1/fixkeybag && chmod 755 /mnt1/fixkeybag && rm -rf $DEVICE_CONFIG_STAGE" || \
        die "Could not install iOS configuration files"
    ssh_device "/sbin/reboot_bak" >/dev/null 2>&1 || true
    log "RootFS installed. Re-enter DFU and run: ./install.sh boot"
}

tether_boot() {
    build_tether_components
    enter_pwned_ibss
    log "Sending iOS 6 iBSS"
    "$TOOLS/irecovery" -f "$TETHER/iBSS.img3" || die "Could not send iBSS"
    sleep 1
    log "Sending iOS 6 iBEC"
    "$TOOLS/irecovery" -f "$TETHER/iBEC.img3" || die "Could not send iBEC"
    wait_recovery
    "$TOOLS/irecovery" -c "setenv boot-args -v amfi=0xff amfi_get_out_of_my_way=1 cs_enforcement_disable=1 pio-error=0" || \
        warn "iBEC did not accept explicit boot-args; patched iBEC embeds them."
    "$TOOLS/irecovery" -c saveenv >/dev/null 2>&1 || true
    wait_recovery
    "$TOOLS/irecovery" -f "$TETHER/DeviceTree.img3" || die "Could not send iOS 6 DeviceTree"
    "$TOOLS/irecovery" -c devicetree || die "Could not execute iOS 6 DeviceTree"
    "$TOOLS/irecovery" -f "$TETHER/kernelcache.img3" || die "Could not send patched iOS 6 kernelcache"
    "$TOOLS/irecovery" -c bootx || die "Kernel boot command failed"
    log "Boot chain sent. Watch device verbose output for fixkeybag and SpringBoard."
}

usage() {
    printf '%s\n' \
        "Usage: $0 {install|boot|help}" \
        "  install     Prepare RootFS, boot SSH ramdisk, repartition, install" \
        "  boot        Tether-boot the installed iOS 6.1.4 system"
}

main() {
    [[ $# == 1 ]] || { usage; exit 2; }
    [[ $1 == "help" ]] && { usage; return 0; }
    mkdir -p "$WORK" "$TETHER"
    check_host
    [[ $1 != install ]] || select_system_ipsw
    case $1 in
        install ) install_rootfs;;
        boot ) tether_boot;;
        * ) usage; exit 2;;
    esac
}

main "$@"
