#!/bin/sh
# Bundle all dependent .dylib into the current folder
# Copyright (c) 2015 Stewart Morgan
# 

if [ -z "$*" ]; then
	printf "\nUsage: $0 file\n\tattempts to find all non-system libraries, copy them, and normalise to '.'\n\n";
	exit;
fi;


#find . -name \*.dylib | while read FILE; do
for FILE in $*; do

	filename=$(basename $FILE)
	echo;
	echo "Considering $FILE : $filename";

	if [ "X${FILE%%.dylib}" != "X${FILE}" ]; then
		echo "==> Changing $FILE -> @executable_path/$filename"
		install_name_tool -id "@executable_path/$filename" $FILE;
	fi;

	# The dependency_files are extracted from otool -L, dylibs are normalised to @executable_path/<libname>.dylib
	# local and system libs / Frameworks are left alone

	dependency_files=" $(otool -XL $FILE \
				| grep -v "${FILE}" \
				| grep -v Frameworks \
				| grep -v '/usr/lib/' \
				| tr " " "\t" | cut -f2,1 \
				| tr "\n" " " |tr "\t" " " \
				) "

	for DEPFILE in $dependency_files; do

		depfilename=$(basename $DEPFILE);

		echo "--> Considering $DEPFILE : $depfilename"

		if [ ! -e "./$depfilename" ]; then
			if [ -e "${DEPFILE}" ]; then
				echo "==> Copying ${DEPFILE}";
				cp "${DEPFILE}" .;
			else
				echo "===> missing: $depfilename";
				continue;
			fi;

		elif [ "X${DEPFILE}" == "X@executable_path/$depfilename" ]; then
			echo "--> Leaving existing bundled file:  $DEPFILE";

		else
			echo "==> Changing $DEPFILE -> @executable_path/$depfilename"
			install_name_tool -change "${DEPFILE}" "@executable_path/${depfilename}" ${FILE}
		fi;
	done;

done
