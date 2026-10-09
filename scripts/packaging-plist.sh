#!/bin/zsh

# Shared plist readers for release packaging. Array membership is checked by
# indexing actual values; rendered descriptions such as "Array { ... }" are
# never compared or copied into signed entitlements.

pastrix_plist_value_contains() {
    local plist="$1"
    local key_path="$2"
    local expected="$3"
    local index
    local value
    local found_indexed_value=false

    index=0
    while value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}:${index}" "$plist" 2>/dev/null)"; do
        found_indexed_value=true
        [[ "$value" == "$expected" ]] && return 0
        (( index += 1 ))
    done
    [[ "$found_indexed_value" == false ]] || return 1

    value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}" "$plist" 2>/dev/null)" || return 1
    [[ "$value" == "$expected" ]]
}

pastrix_plist_scalar_environment() {
    local plist="$1"
    local key_path="$2"
    local value

    # A successful index lookup means the value is an array, not a scalar.
    if /usr/libexec/PlistBuddy -c "Print :${key_path}:0" "$plist" >/dev/null 2>&1; then
        return 1
    fi
    value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}" "$plist" 2>/dev/null)" || return 1
    [[ "$value" == "Development" || "$value" == "Production" ]] || return 1
    print -r -- "$value"
}

pastrix_select_cloudkit_environment() {
    local profile_plist="$1"
    local key_path="$2"
    local requested_environment="$3"
    local is_developer_id="$4"
    local count
    local first_value

    first_value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}:0" "$profile_plist" 2>/dev/null || true)"
    if [[ -z "$first_value" ]] && ! pastrix_plist_scalar_environment "$profile_plist" "$key_path" >/dev/null; then
        print -u2 "Provisioning profile iCloud container environment must be a non-empty string or array."
        return 1
    fi

    if [[ "$is_developer_id" == true ]]; then
        pastrix_plist_value_contains "$profile_plist" "$key_path" "Production" || {
            print -u2 "Developer ID provisioning profile does not authorize the Production iCloud environment."
            return 1
        }
        [[ -z "$requested_environment" || "$requested_environment" == "Production" ]] || {
            print -u2 "Developer ID CloudKit builds must explicitly use the Production environment."
            return 1
        }
        print -r -- "Production"
        return 0
    fi

    if [[ -n "$requested_environment" ]]; then
        pastrix_plist_value_contains "$profile_plist" "$key_path" "$requested_environment" || {
            print -u2 "Requested iCloud container environment is not authorized by the provisioning profile."
            return 1
        }
        print -r -- "$requested_environment"
        return 0
    fi

    if [[ -z "$first_value" ]]; then
        pastrix_plist_scalar_environment "$profile_plist" "$key_path"
        return
    fi

    count=0
    while /usr/libexec/PlistBuddy -c "Print :${key_path}:${count}" "$profile_plist" >/dev/null 2>&1; do
        (( count += 1 ))
    done
    (( count == 1 )) || {
        print -u2 "Provisioning profile permits multiple iCloud environments; select one explicitly in the entitlements."
        return 1
    }
    print -r -- "$first_value"
}
