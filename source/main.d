/**
	ext4rescue main module.

	Copyright:
	This file is part of ext4rescue $(LINK https://github.com/epi/ext4rescue)
	Copyright (C) 2014 Adrian Matoga

	ext4rescue is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	ext4rescue is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with ext4rescue.  If not, see $(LINK http://www.gnu.org/licenses/).
*/
module main;

import std.bitmanip;
import std.exception;
import std.stdio;
import std.getopt;
import std.typecons : scoped;
import std.range : enumerate;

import ddrescue;
import ext4;
import extract;
import filecache;
import filetree;
import scan;

enum ListMode { none, all, bad }

void listFiles(FileTree fileTree, Ext4 ext4, ListMode listMode)
{
	if (listMode == ListMode.none)
		return;

	auto namer = scoped!NamingVisitor();
	foreach (inodeNum; 2 .. ext4.inodes.length + 1)
	{
		SomeFile sf = fileTree.filesByInodeNum.get(inodeNum, null);
		if (sf)
		{
			if (listMode == ListMode.bad && sf.ok)
				continue;
			writef("%10d %s ", inodeNum, sf.status);
			if (sf.inodeIsOk)
			{
				auto inode = ext4.inodes[sf.inodeNum];
				writef("%s %3d/%3d %5d %5d %10d ", inode.mode, sf.foundLinkCount, sf.linkCount, inode.i_uid, inode.i_gid, inode.size);
			}
			else
			{
				static class ModeVisitor : FileVisitor
				{
					char mode;
					void visit(RegularFile rf) { mode = '-'; }
					void visit(Directory d) { mode = 'd'; }
					void visit(SymbolicLink sl) { mode = 'l'; }
				}
				auto modeVisitor = scoped!ModeVisitor();
				sf.accept(modeVisitor);
				writef("%c          %3d                            ", modeVisitor.mode, sf.foundLinkCount);
			}
			sf.accept(namer);
			writefln("%-(%s%|\n                                                            %)", namer.names);
		}
	}
}

void showSummary(FileTree fileTree, Ext4 ext4)
{
	// All byte counts fit in ulong, as maximum file system size is 1 EiB (i.e. 2^^60).
	// All file counts fit in uint, as maximum number of files in a file system is 2^^32 minus a few.
	static struct Summary
	{
		uint fileCount;            /// number of files of specific type
		uint goodInodeCount;       /// number of good inodes
		uint badInodeCount;        /// number of bad inodes
		uint badMapCount;          /// number of files with bad block map/extent tree
		uint unnamedFileCount;     /// number of files for which names were not found
		ulong declaredByteCount;   /// number of bytes in blocks declared in inodes as i_blocks_high/_lo
		ulong mapByteCount;        /// number of bytes in readable block map/extent tree blocks
		ulong reachableByteCount;  /// number of bytes in blocks reachable via block maps/extent trees
		ulong readableByteCount;   /// number of readable bytes in data blocks
		ulong badByteCount;        /// number of unreadable bytes in data blocks
	}

	class SummaryVisitor : FileVisitor
	{
		Summary regularFileSummary;
		Summary directorySummary;
		Summary symbolicLinkSummary;

		void accumulate(SomeFile f, ref Summary s)
		{
			if (f.inodeIsOk)
			{
				++s.goodInodeCount;
				s.declaredByteCount += f.byteCount;
				s.mapByteCount += f.mapByteCount;
				s.reachableByteCount += f.reachableByteCount;
				s.readableByteCount += f.readableByteCount;
				if (!f.blockMapIsOk)
					++s.badMapCount;
			}
			else
			{
				++s.badInodeCount;
			}
			if (f.status.nameUnknown)
				++s.unnamedFileCount;
		}

		void visit(Directory d) { accumulate(d, directorySummary); }
		void visit(RegularFile f) { accumulate(f, regularFileSummary); }
		void visit(SymbolicLink l) { accumulate(l, symbolicLinkSummary); }

		void postprocess(ref Summary s)
		{
			s.fileCount = s.badInodeCount + s.goodInodeCount;
			s.badByteCount = s.reachableByteCount - s.readableByteCount;
		}

		void postprocess()
		{
			postprocess(regularFileSummary);
			postprocess(directorySummary);
			postprocess(symbolicLinkSummary);
		}

		auto getFieldForAllTypes(string s)() if (__traits(compiles, mixin("Summary.init." ~ s)))
		{
			alias FieldType = typeof(mixin("Summary." ~ s ~ ".init"));
			FieldType[4] result;
			result[0] = mixin("regularFileSummary." ~ s);
			result[1] = mixin("directorySummary." ~ s);
			result[2] = mixin("symbolicLinkSummary." ~ s);
			result[3] = result[0] + result[1] + result[2];
			return result;
		}
	}

	auto visitor = new SummaryVisitor();
	foreach (i, sf; fileTree.filesByInodeNum)
		sf.accept(visitor);
	visitor.postprocess();

	writefln("%-30s%20s%20s%20s%20s", "file type", "regular file", "directory", "symbolic link", "all");
	writefln("%-30s%-(%20s%)", "number of files", visitor.getFieldForAllTypes!"fileCount"());
	writefln("%-30s%-(%20s%)", "good inodes", visitor.getFieldForAllTypes!"goodInodeCount"());
	writefln("%-30s%-(%20s%)", "bad inodes", visitor.getFieldForAllTypes!"badInodeCount"());
	writefln("%-30s%-(%20s%)", "files with bad map/tree", visitor.getFieldForAllTypes!"badMapCount"());
	writefln("%-30s%-(%20s%)", "files with no name", visitor.getFieldForAllTypes!"unnamedFileCount"());
	writefln("%-30s%-(%20s%)", "declared bytes", visitor.getFieldForAllTypes!"declaredByteCount"());
	writefln("%-30s%-(%20s%)", "bytes in map/tree blocks", visitor.getFieldForAllTypes!"mapByteCount"());
	writefln("%-30s%-(%20s%)", "reachable data bytes", visitor.getFieldForAllTypes!"reachableByteCount"());
	writefln("%-30s%-(%20s%)", "readable data bytes", visitor.getFieldForAllTypes!"readableByteCount"());
	writefln("%-30s%-(%20s%)", "unreadable data bytes", visitor.getFieldForAllTypes!"badByteCount"());
}

void showTree(FileTree fileTree)
{
	Directory currentDir;
	uint indent;
	ulong pipeMask;
	auto visitor = new class FileVisitor
	{
		void visit(Directory d)
		{
			if (d.name)
				writeln(d.name);
			else if (d.inodeNum == 2)
				writeln("/");
			else
				writefln("~~DIR@%s", d.inodeNum);
			auto temp = currentDir;
			currentDir = d;
			++indent;
			pipeMask |= 1UL << indent;
			foreach (i, c; d.children[].enumerate())
			{
				foreach (j; 0 .. indent)
				{
					if (pipeMask & (1UL << j))
						write("\x1b(0x\x1b(B ");
					else
						write("  ");
				}
				if (i == d.children.length - 1)
				{
					write("\x1b(0mq\x1b(B");
					pipeMask &= ~(1UL << indent);
				}
				else
					write("\x1b(0tq\x1b(B");
				c.accept(this);
			}
			--indent;
			currentDir = temp;
		}

		void visitMLF(MultiplyLinkedFile mlf, string placeholderName)
		{
			foreach (l; mlf.links)
			{
				if (l.parent is currentDir)
				{
					writeln(l.name);
					return;
				}
			}
			writefln("~~%s@%s", placeholderName, mlf.inodeNum);
		}

		void visit(RegularFile f)
		{
			visitMLF(f, "FILE");
		}

		void visit(SymbolicLink l)
		{
			visitMLF(l, "SYMLINK");
		}
	};
	pipeMask = 1;
	foreach (i, root; fileTree.roots)
	{
		if (i == fileTree.roots.length - 1)
			pipeMask &= ~1UL;
		write("*\x1b(0q\x1b(B");
		root.accept(visitor);
	}
}

// return 2 if command line could not be parsed
private int errorCode = 2;

bool showHelp(string[] args)
{
	bool helpWanted;
	getopt(args, std.getopt.config.passThrough, "h|help", &helpWanted);
	if (!helpWanted)
		return false;

	errorCode = 1;

	enum consoleTextWhite = "\x1b[1;37m";
	enum consoleTextReset = "\x1b[0m";

	writeln(
		"ext4rescue is a tool for automated data recovery from ext4 file systems that\n" ~
		"have been corrupted due to a damage of the underlying physical media.\n\n" ~
		"Usage: " ~ args[0] ~ " [OPTION]... IMAGE [DDRESCUE_LOG]\n" ~
		"       " ~ args[0] ~ " [OPTION]... -L bad|all [-r] [DIR]...\n\n" ~
		"The first syntax is used to analyze ext4 file system IMAGE and optionally\n" ~
		"extract files from it.\n" ~
		"If DDRESCUE_LOG file is not given, the IMAGE is assumed to be entirely correct.\n" ~
		"Upon extraction, files with issues are marked with extended attribute\n" ~
		"user.ext4rescue.status.\n" ~
		"The second syntax (with -L) can be used to display the status of previously\n" ~
		"extracted files.\n\n" ~
		"Mandatory arguments to long options are mandatory for short options too.\n" ~
		" -s  --summary       Show collective statistics of the damaged file system.\n" ~
		" -l  --list=all|bad  List files and their attributes.\n" ~
		" -T  --tree          List all files in the form of a tree.\n" ~
		" -t  --to=DIR        Extract files to the specified DIR.\n" ~
		" -f  --from=PATH     Specify PATHs to extract (can be used multiple times).\n" ~
		"                     If not specified, everything is extracted.\n" ~
		" -c  --chown         Set user ID and group ID for extracted files (requires\n" ~
		"                     root privileges)\n" ~
		" -F  --force-scan    Analyze the disk image even if cached analysis result\n" ~
		"                     is present.\n" ~
		" -L  --list-extracted=all|bad\n" ~
		"                     List previously extracted files.\n" ~
		" -r  --recursive     Only with -L: list files recursively.\n" ~
		" -h  --help          Print this help.\n\n" ~
		"Status letters:\n" ~
		" i  The inode is not readable\n" ~
		" p  Parent directory is not known\n" ~
		" n  No name associated with the file has been found\n" ~
		" l  Some links to the file are missing\n" ~
		" m  Block map or extent tree is partially or entirely damaged\n" ~
		" d  Some or all data blocks are damaged\n\n" ~
		consoleTextWhite ~
		"IMPORTANT!!! Use GNU ddrescue(1) first to create a copy of the damaged media.\n" ~
		"ext4rescue used directly on such media will not work correctly and may cause\n" ~
		"further damage!" ~
		consoleTextReset);
	return true;
}

bool listExtractedFiles(string[] args)
{
	import std.path : buildPath;
	import std.file : dirEntries, SpanMode;
	import std.string : toStringz;
	import std.algorithm : splitter, startsWith;
	import core.sys.linux.sys.xattr : llistxattr, lgetxattr;

	ListMode listMode;
	bool recursive;

	getopt(args, std.getopt.config.passThrough, "L|list-extracted", &listMode);
	if (listMode == ListMode.init)
		return false;

	getopt(args, "r|recursive", &recursive);

	if (args.length < 2)
		args ~= ".";

	errorCode = 1;

	char[65536] buf;
	foreach (path; args[1 ..  $])
	{
		auto prefix = buildPath(path, ".")[0 .. $ - 1];
		writeln(prefix);
		foreach (e; dirEntries(path, recursive ? SpanMode.breadth : SpanMode.shallow, false))
		{
			auto displayName = e.name.startsWith(prefix) ? e.name[prefix.length .. $] : e.name;
			auto namez = e.name.toStringz();
			long s = llistxattr(namez, buf.ptr, buf.length);
			errnoEnforce(s >= 0, "llistxattr: " ~ e.name);
			bool listed = false;
			foreach (attr; buf[0 .. s].splitter("\0"))
			{
				if (attr.startsWith("user.ext4rescue"))
				{
					s = lgetxattr(namez, attr.ptr, buf.ptr, buf.length);
					errnoEnforce(s >= 0, "lgetxattr: " ~ e.name);
					writeln(buf[0 .. s], " ", displayName);
					listed = true;
				}
			}
			if (!listed && listMode == ListMode.all)
				writeln(FileStatus.init, " ", displayName);
		}
	}
	return true;
}

int main(string[] args)
{
	bool forceScan;
	bool summary;
	ListMode listMode;
	bool tree;
	string[] srcPaths;
	string destPath;
	bool chown;

	try
	{
		if (showHelp(args))
			return 0;

		if (listExtractedFiles(args))
			return 0;

		getopt(args,
			"s|summary",    &summary,
			"l|list",       &listMode,
			"T|tree",       &tree,
			"t|to",         &destPath,
			"f|from",       &srcPaths,
			"c|chown",      &chown,
			"F|force-scan", &forceScan);

		enforce(args.length >= 2, "Missing ext4 file system image name");

		// return 1 if command line was parsed correctly but something went wrong later
		errorCode = 1;

		ExtractTarget extractTarget = destPath ? new DirectoryExtractTarget(destPath, chown) : null;

		string imageName = args[1];
		string ddrescueLogName;
		Region[] regions;
		if (args.length > 2)
		{
			ddrescueLogName = args[2];
			regions = parseLog(File(ddrescueLogName).byLine());
		}
		if (regions.length == 0)
			regions ~= Region(0, getFileSize(imageName), true);
		regions = regions.addRandomDamage(1300, 10240);
		debug writeln(regions);

		scope ext4 = new Ext4(imageName, regions);
		debug
		{
			writefln("Block size:   %12s", ext4.blockSize);
			writefln("Inode count:  %12s", ext4.inodes.length);
			ext4.superBlock.dump();
		}

		FileTree fileTree;

		if (!forceScan)
		{
			try
			{
				fileTree = readCachedFileTree(imageName, ddrescueLogName);
			}
			catch (Exception e)
			{
				stderr.writeln("Could not read cached file tree: ", e.msg);
			}
		}

		if (!fileTree)
		{
			fileTree = scanInodesAndDirectories(ext4,
				(uint current, uint total) {
					stdout.writef("Scanning inodes and directories... %3d%%\r", current * 100UL / total);
					stdout.flush();
					return true;
				});
			writeln();
			if (!fileTree.get!Directory(2).inodeIsOk)
			{
				writeln("Root directory inode is damaged. Trying to find root directory data...");
				findRootDirectoryContents(ext4, fileTree);
			}
			cacheFileTree(imageName, ddrescueLogName, fileTree);
		}

		listFiles(fileTree, ext4, listMode);
		if (summary)
			showSummary(fileTree, ext4);
		if (tree)
			showTree(fileTree);

		if (destPath)
		{
			import std.algorithm.comparison : predSwitch;

			SomeFile[] srcFiles;
			if (srcPaths.length)
			{
				foreach (path; srcPaths)
					srcFiles ~= fileTree.getByPath(path);
			}
			else
				srcFiles = fileTree.roots[];

			ulong totalByteCount;
			ulong outByteCount;
			uint outFileCount;
			foreach (file; srcFiles)
			{
				countFilesAndBytes(file, ext4, outFileCount, outByteCount);
				totalByteCount += outByteCount;
			}
			foreach (file; srcFiles)
				extract.extract(file, ext4, extractTarget,
					(ulong writtenByteCount, ExtractType type, in char[] path, in char[] orig)
					{
						writef("(%5.2f%%) %s %s",
							writtenByteCount * 100.0 / totalByteCount,
							type.predSwitch(
								ExtractType.file, "f",
								ExtractType.dir, "d",
								ExtractType.symlink, "l",
								ExtractType.hardlink, "h"),
							path);
						if (orig.length > 0)
							write(" -> ", orig);
						writeln();
						return false;
					});
		}
	}
	catch (Exception e)
	{
		debug stderr.writeln(e);
		else stderr.writeln(args[0], ": ", e.msg);
		return errorCode;
	}
	return 0;
}
