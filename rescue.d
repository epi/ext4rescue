import std.algorithm;
import std.array;
import std.format;
import std.string;
import std.stdio;

import bits;
import blockcache;
import defs;
import ext4;

class Rescue
{
	private Ext4 _ext4;

	this(Ext4 ext4)
	{
		_ext4 = ext4;
	}

	static class Item
	{
		Directory parent;
		uint inodeNum;
		uint[string] names;
		uint linkCount;
		ulong byteCount;
		ulong size;

		abstract @property string typeStr() const pure nothrow;

		@property string[] whatsWrong() const
		{
			string[] result;
			if (linkCount != foundLinkCount())
				result ~= "not all links found";
			if (inodeNum != 2 && parent is null)
				result ~= "parent is not known";
			return result;
		}

		@property uint foundLinkCount() const
		{
			return names.values.sum();
		}
		bool inodeIsOk;

		@property bool allGood() const
		{
			return inodeIsOk && linkCount == foundLinkCount();
		}

		string[] fullPath() const
		out (result)
		{
			assert(result.length > 0);
		}
		body
		{
			string parentPath;
			if (inodeNum == 2)
				return [ "" ];
			else if (!parent)
				parentPath = "/@UNKNOWN_PARENT/";
			else
				parentPath = parent.fullPath[0] ~ "/";
			auto result = names.keys.filter!`a != "." && a != ".."`().array();
			if (result.length == 0)
				result ~= format("@%s%08x", typeStr, inodeNum);
			return result.map!(a => parentPath ~ a)().array();
		}

		void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
		{
			import std.conv;

			formatValue(sink, inodeNum, fmt);
			sink(". ");
			sink(parent !is null ? to!string(parent) : "no parent");
			sink(" ");
			formatValue(sink, foundLinkCount, fmt);
			sink("/");
			formatValue(sink, linkCount, fmt);
			foreach (name, count; names)
			{
				sink(" ");
				sink(name);
				sink("(");
				formatValue(sink, count, fmt);
				sink(")");
			}
		}
	}

	static class Directory : Item
	{
		this(uint inodeNum)
		{
			this.inodeNum = inodeNum;
		}

		override @property string[] whatsWrong() const
		{
			string[] result = super.whatsWrong();
			if (!directoryIsOk)
				result ~= "errors in directory structure";
			return result;
		}

		override @property string typeStr() const pure nothrow
		{
			return "DIR";
		}

		override @property bool allGood() const
		{
			return super.allGood && directoryIsOk;
		}

		override void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
		{
			sink("DIR @");
			super.toString(sink, fmt);
		}

		bool directoryIsOk = true;
	}

	static class File : Item
	{
		this(uint inodeNum)
		{
			this.inodeNum = inodeNum;
		}

		override @property string typeStr() const pure nothrow
		{
			return "FILE";
		}

		override void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
		{
			sink("FILE @");
			super.toString(sink, fmt);
		}
	}

	Item[uint] itemsByInodeNum;

	T getItem(T)(uint inodeNum)
		if (is(T : Item))
	{
		auto item = cast(T) itemsByInodeNum.get(inodeNum, null);
		if (!item)
		{
			item = new T(inodeNum);
			itemsByInodeNum[inodeNum] = item;
		}
		return item;
	}

	/// Scan directory entries and associate inodes with names.
	private void scanDirectory(Directory thisDir)
	{
		foreach (entry; _ext4.inodes[thisDir.inodeNum].readAsDir())
		{
			writef("%10d %d %s\r", entry.inode, entry.file_type, entry.name);
			if (entry.file_type == ext4_dir_entry_2.Type.dir)
			{
				Directory dir = getItem!Directory(entry.inode);
				//dir.parent = thisDir;
				if (entry.name == ".")
				{
					if (dir !is thisDir)
						dir.directoryIsOk = false;
				}
				else if (entry.name == "..")
				{
					if (thisDir.parent)
						thisDir.parent = dir;
					else if (thisDir.parent !is dir)
						dir.directoryIsOk = false;
				}
				else
				{
					if (!dir.parent)
						dir.parent = thisDir;
					else if (dir.parent !is thisDir)
						dir.directoryIsOk = false;
				}
				++dir.names[entry.name];
			}
			else if (entry.file_type == ext4_dir_entry_2.Type.file)
			{
				File file = getItem!File(entry.inode);
				++file.names[entry.name];
				file.parent = thisDir;
			}
		}
	}

	private void setItemProperties(Item item, Ext4.Inode inode)
	{
		item.inodeIsOk = inode.ok;
		item.linkCount = inode.i_links_count;
		item.byteCount = inode.blockCount * 512;
		item.size = inode.size;
	}

	uint unreadableInodes;

	void scan()
	{
		foreach (inode; _ext4.inodes[])
		{
			if (inode.inodeNum != 2 && inode.inodeNum < 11)
				continue;
			if (!inode.ok)
				++unreadableInodes;

			if (inode.ok && !inode.i_dtime)
			{
				if (inode.mode.type == Mode.Type.dir)
				{
					Directory dir = getItem!Directory(inode.inodeNum);
					setItemProperties(dir, inode);
					scanDirectory(dir);
				}
				else if (inode.mode.type == Mode.Type.file)
				{
					File f = getItem!File(inode.inodeNum);
					setItemProperties(f, inode);
				}
			}
		}
	//	writefln("%(%s%|\n%)", rescuedItemsByInodeNum.values);
		writeln("\nsearch complete");
		writeln(itemsByInodeNum.length);
		foreach (k, v; itemsByInodeNum)
		{
/*			if ((k == 2 || k >= 11) && !v.allGood)
			{
				writeln(v);
			}*/
			if (!v.allGood)
			{
				writeln(k, " ", v.fullPath, " ", v.whatsWrong());
			}
		}
	}
}
