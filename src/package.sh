fix_broken_links () {
	local dst_dir
	expect_args dst_dir -- "$@"
	expect_existing "${dst_dir}"

	local link
	while read -r link; do
		local link_dir link_name src_original src_canonical src_name
		link_dir=$( dirname "${dst_dir}/${link}" ) || return 1
		link_name=$( basename "${link}" ) || return 1
		src_original=$( readlink "${dst_dir}/${link}" ) || return 1
		src_canonical=$( get_link_path "${dst_dir}/${link}" ) || return 1
		src_name=$( basename "${src_canonical}" ) || return 1

		if [[ ! -e "${src_canonical}" ]]; then
			rm -f "${dst_dir}/${link}" || return 1

			local target
			if target=$( find_tree "${link_dir}" -name "${src_name}" | match_exactly_one ); then
				log_indent "Fixing broken link: ${link_name} -> ${src_name} (${src_original})"
				ln -s "${target}" "${dst_dir}/${link}" || return 1
			else
				log_warning "Broken link: ${dst_dir}/${link} -> ${src_original}"
			fi
		fi
	done < <( find_tree "${dst_dir}" -type l | sort_natural )
}


install_deb_package () {
	local package_file dst_dir
	expect_args package_file dst_dir -- "$@"
	expect_existing "${package_file}"

	local package_name src_dir
	package_name=$( basename "${package_file}" ) || return 1
	src_dir=$( get_tmp_dir 'deb' ) || return 1

	log "Installing OS package: ${package_name}"

	dpkg --extract "${package_file}" "${src_dir}" 2>&1 | quote || return 1

	copy_dir_into "${src_dir}" "${dst_dir}" || return 1
	rm -rf "${src_dir}" || return 1
}


install_rpm_package () {
	local package_file dst_dir
	expect_args package_file dst_dir -- "$@"
	expect_existing "${package_file}"

	local package_name src_dir
	package_name=$( basename "${package_file}" ) || return 1
	src_dir=$( get_tmp_dir 'rpm' ) || return 1

	log "Installing OS package: ${package_name}"

	mkdir -p "${src_dir}" || return 1
	(
		cd "${src_dir}" &&
		rpm2cpio "${package_file}" | cpio --extract --make-directories >'/dev/null' 2>&1
	) || return 1

	copy_dir_into "${src_dir}" "${dst_dir}" || return 1
	rm -rf "${src_dir}" || return 1
}


install_debian_packages () {
	local names dst_dir
	expect_args names dst_dir -- "$@"

	local -a names_a
	names_a=( ${names} )
	if [[ -z "${names_a[@]:+_}" ]]; then
		return 0
	fi

	local apt_dir
	if [[ -z "${BASHMENOT_APT_DIR:-}" ]]; then
		apt_dir=$( get_tmp_dir 'apt' ) || return 1
	else
		apt_dir="${BASHMENOT_APT_DIR}"
	fi

	local -a opts_a
	opts_a+=( -o debug::nolocking='true' )
	opts_a+=( -o dir::cache="${apt_dir}/cache" )
	opts_a+=( -o dir::state="${apt_dir}/state" )

	local must_update
	must_update=1
	if [[ -d "${apt_dir}" ]]; then
		local now candidate_time
		now=$( get_current_time )
		if candidate_time=$( get_modification_time "${apt_dir}" ) &&
			(( candidate_time + 3600 >= now ))
		then
			must_update=0
		fi
	else
		rm -rf "${apt_dir}" || return 1
	fi

	rm -rf "${apt_dir}/cache/archives" || return 1
	mkdir -p "${apt_dir}/cache/archives/partial" "${apt_dir}/state/lists/partial" || return 1

	if (( must_update )); then
		apt-get "${opts_a[@]}" update 2>&1 | quote || return 1

		touch "${apt_dir}" || return 1
	fi

	local name
	for name in "${names_a[@]}"; do
		mkdir -p "${apt_dir}/cache/archives/partial" || return 1

		apt-get "${opts_a[@]}" install --download-only --reinstall --yes "${name}" 2>&1 | quote || return 1

		local file
		find_tree "${apt_dir}/cache/archives" -type f -name '*.deb' |
			sort_natural |
			while read -r file; do
				install_deb_package "${apt_dir}/cache/archives/${file}" "${dst_dir}" || return 1
			done

		rm -rf "${apt_dir}/cache/archives" || return 1
	done

	if [[ -z "${BASHMENOT_APT_DIR:-}" ]]; then
		rm -rf "${apt_dir}" || return 1
	fi

	fix_broken_links "${dst_dir}" || return 1
}


install_redhat_packages () {
	local names dst_dir
	expect_args names dst_dir -- "$@"

	local -a names_a
	names_a=( ${names} )
	if [[ -z "${names_a[@]:+_}" ]]; then
		return 0
	fi

	local yum_dir
	yum_dir=$( get_tmp_dir 'yum' ) || return 1

	local -a opts_a
	opts_a+=( --assumeyes )
	opts_a+=( --downloadonly )
	opts_a+=( --downloaddir="${yum_dir}" )

	# NOTE: In old versions of yum, the --downloadonly option is
	# provided by yum-plugin-downloadonly, which must be installed
	# manually, and which causes yum to always return failure.

	local platform no_status
	platform=$( detect_platform )
	no_status=0
	if [[ "${platform}" == 'linux-centos-6-x86_64' ]]; then
		no_status=1
	fi

	local name
	for name in "${names_a[@]}"; do
		local status
		status=0

		if ! yum list installed "${name}" >'/dev/null' 2>&1; then
			if ! yum install "${opts_a[@]}" "${name}" 2>&1 | quote; then
				status=1
			fi
		elif ! yum reinstall "${opts_a[@]}" "${name}" 2>&1 | quote; then
			status=1
		fi
		if ! (( no_status )) && (( status )); then
			return 1
		fi

		local file
		find_tree "${yum_dir}" -type f -name '*.rpm' |
			sort_natural |
			while read -r file; do
				install_rpm_package "${yum_dir}/${file}" "${dst_dir}" || return 1
			done

		rm -rf "${yum_dir}" || return 1
	done

	fix_broken_links "${dst_dir}" || return 1
}


install_platform_packages () {
	local specs dst_dir
	expect_args specs dst_dir -- "$@"

	local platform
	platform=$( detect_platform )

	local -a specs_a
	specs_a=( ${specs} )
	if [[ -z "${specs_a[@]:+_}" ]]; then
		return 0
	fi

	local -a names_a
	local spec
	for spec in "${specs_a[@]}"; do
		local pattern name
		pattern="${spec%:*}"
		name="${spec#*:}"
		if [[ "${pattern}" == "${name}" || "${platform}" =~ ${pattern} ]]; then
			names_a+=( "${name}" )
		fi
	done
	if [[ -z "${names_a[@]:+_}" ]]; then
		return 0
	fi

	local names
	names=$( IFS=$'\n' && echo "${names_a[*]}" )

	case "${platform}" in
	'linux-debian-'*|'linux-ubuntu-'*)
		install_debian_packages "${names}" "${dst_dir}" || return 1
		;;
	'linux-centos-'*|'linux-fedora-'*)
		install_redhat_packages "${names}" "${dst_dir}" || return 1
		;;
	*)
		local description
		description=$( format_platform_description "${platform}" )

		log_error "Unexpected platform: ${description}"
		return 1
	esac
}
