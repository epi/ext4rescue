/**
 * Struct definitions, constants and inline functions
 * adapted from linux/fs/ext4/ext4.h
 *
 * Copyright: (C) 1992, 1993, 1994, 1995
 * Remy Card (card@masi.ibp.fr)
 * Laboratoire MASI - Institut Blaise Pascal
 * Universite Pierre et Marie Curie (Paris VI)
 *
 *  from
 *
 *  linux/include/linux/minix_fs.h
 *
 *  Copyright (C) 1991, 1992  Linus Torvalds
 */
module defs;

import std.bitmanip;
import std.traits;

import bits;

version (LittleEndian)
{
	alias __le16 = ushort;
	alias __le32 = uint;
	alias __le64 = ulong;
}
else version (BigEndian)
{
	static assert(0, "big endian version not implemented");
}
else
{
	static assert(0, "unsupported endianness");
}

alias __u8  = ubyte;
alias __u16 = ushort;
alias __u32 = uint;
alias __u64 = ulong;

alias __s8  = byte;
alias __s16 = short;
alias __s32 = int;
alias __s64 = long;

/// Structure of the super block
struct ext4_super_block
{
	/*00*/
	__le32  s_inodes_count;         /// Inodes count
	__le32  s_blocks_count_lo;      /// Blocks count
	__le32  s_r_blocks_count_lo;    /// Reserved blocks count
	__le32  s_free_blocks_count_lo; /// Free blocks count
	/*10*/
 	__le32  s_free_inodes_count;    /// Free inodes count
	__le32  s_first_data_block;     /// First Data Block
	__le32  s_log_block_size;       /// Block size
	__le32  s_log_cluster_size;     /// Allocation cluster size
 	/*20*/
 	__le32  s_blocks_per_group;     /// # Blocks per group
	__le32  s_clusters_per_group;   /// # Clusters per group
	__le32  s_inodes_per_group;     /// # Inodes per group
	__le32  s_mtime;                /// Mount time
	/*30*/
	__le32  s_wtime;                /// Write time
	__le16  s_mnt_count;            /// Mount count
	__le16  s_max_mnt_count;        /// Maximal mount count
	__le16  s_magic;                /// Magic signature
	__le16  s_state;                /// File system state
	__le16  s_errors;               /// Behaviour when detecting errors
	__le16  s_minor_rev_level;      /// minor revision level
	/*40*/
	__le32  s_lastcheck;            /// time of last check
	__le32  s_checkinterval;        /// max. time between checks
	__le32  s_creator_os;           /// OS
	__le32  s_rev_level;            /// Revision level
	/*50*/
	__le16  s_def_resuid;           /// Default uid for reserved blocks
	__le16  s_def_resgid;           /// Default gid for reserved blocks
	/*
	 * These fields are for EXT4_DYNAMIC_REV superblocks only.
	 *
	 * Note: the difference between the compatible feature set and
	 * the incompatible feature set is that if there is a bit set
	 * in the incompatible feature set that the kernel doesn't
	 * know about, it should refuse to mount the filesystem.
	 *
	 * e2fsck's requirements are more strict; if it doesn't know
	 * about a feature in either the compatible or incompatible
	 * feature set, it must abort and not try to meddle with
	 * things it doesn't understand...
	 */
	__le32  s_first_ino;            /// First non-reserved inode
	__le16  s_inode_size;           /// size of inode structure
	__le16  s_block_group_nr;       /// block group # of this superblock
	union {
		__le32  s_feature_compat;       /// compatible feature set
		mixin(bitfields!(
			bool, "s_feature_compat_dir_prealloc", 1,
			bool, "s_feature_compat_imagic_inodes", 1,
			bool, "s_feature_compat_has_journal", 1,
			bool, "s_feature_compat_ext_attr", 1,

			bool, "s_feature_compat_resize_inode", 1,
			bool, "s_feature_compat_dir_index", 1,
			bool, "s_feature_compat_lazy_bg", 1,
			bool, "s_feature_compat_exclude_inode", 1,

			bool, "s_feature_compat_exclude_bitmap", 1,
			bool, "s_feature_compat_sparse_super2", 1,

			uint, "s_feature_compat___reserved1", 22));
	}
 	/*60*/
	union {
		__le32  s_feature_incompat;     /// incompatible feature set
		mixin(bitfields!(
			bool, "s_feature_incompat_compression", 1,
			bool, "s_feature_incompat_filetype", 1,
			bool, "s_feature_incompat_recover", 1,
			bool, "s_feature_incompat_journal_dev", 1,

			bool, "s_feature_incompat_meta_bg", 1,
			bool, "s_feature_incompat___reserved1", 1,
			bool, "s_feature_incompat_extents", 1,
			bool, "s_feature_incompat_64bit", 1,

			bool, "s_feature_incompat_mmp", 1,
			bool, "s_feature_incompat_flex_bg", 1,
			bool, "s_feature_incompat_ea_inode", 1,
			bool, "s_feature_incompat___reserved2", 1,

			bool, "s_feature_incompat_dirdata", 1,
			bool, "s_feature_incompat_bg_use_meta_csum", 1,
			bool, "s_feature_incompat_largedir", 1,
			bool, "s_feature_incompat_inline_data", 1,

			uint, "s_feature_incompat___reserved3", 16));
	}
	union {
		__le32  s_feature_ro_compat;    /// readonly-compatible feature set
		mixin(bitfields!(
			bool, "s_feature_ro_compat_sparse_super", 1,
			bool, "s_feature_ro_compat_large_file", 1,
			bool, "s_feature_ro_compat_btree_dir", 1,
			bool, "s_feature_ro_compat_huge_file", 1,

			bool, "s_feature_ro_compat_gdt_csum", 1,
			bool, "s_feature_ro_compat_dir_nlink", 1,
			bool, "s_feature_ro_compat_extra_isize", 1,
			bool, "s_feature_ro_compat_has_snapshot", 1,

			bool, "s_feature_ro_compat_quota", 1,
			bool, "s_feature_ro_compat_bigalloc", 1,
			bool, "s_feature_ro_compat_metadata_csum", 1,

			uint, "s_feature_ro_compat___reserved1", 21));
	}
 	/*68*/
 	__u8    s_uuid[16];             /// 128-bit uuid for volume
 	/*78*/
 	char    s_volume_name[16];      /// volume name
 	/*88*/
 	char    s_last_mounted[64];     /// directory where last mounted
 	/*C8*/
 	__le32  s_algorithm_usage_bitmap; /// For compression
	/*
	 * Performance hints.  Directory preallocation should only
	 * happen if the EXT4_FEATURE_COMPAT_DIR_PREALLOC flag is on.
	 */
	__u8    s_prealloc_blocks;      /// Nr of blocks to try to preallocate
	__u8    s_prealloc_dir_blocks;  /// Nr to preallocate for dirs
	__le16  s_reserved_gdt_blocks;  /// Per group desc for online growth
	/*
	 * Journaling support valid if EXT4_FEATURE_COMPAT_HAS_JOURNAL set.
	 */
 	/*D0*/
 	__u8    s_journal_uuid[16];     /// uuid of journal superblock
 	/*E0*/
 	__le32  s_journal_inum;         /// inode number of journal file
	__le32  s_journal_dev;          /// device number of journal file
	__le32  s_last_orphan;          /// start of list of inodes to delete
	__le32  s_hash_seed[4];         /// HTREE hash seed
	__u8    s_def_hash_version;     /// Default hash version to use
	__u8    s_jnl_backup_type;
	__le16  s_desc_size;            /// size of group descriptor
	/*100*/
	__le32  s_default_mount_opts;
	__le32  s_first_meta_bg;        /// First metablock block group
	__le32  s_mkfs_time;            /// When the filesystem was created
	__le32  s_jnl_blocks[17];       /// Backup of the journal inode
	/* 64bit support valid if EXT4_FEATURE_COMPAT_64BIT */
 	/*150*/
 	__le32  s_blocks_count_hi;      /// Blocks count
	__le32  s_r_blocks_count_hi;    /// Reserved blocks count
	__le32  s_free_blocks_count_hi; /// Free blocks count
	__le16  s_min_extra_isize;      /// All inodes have at least # bytes
	__le16  s_want_extra_isize;     /// New inodes should reserve # bytes
	__le32  s_flags;                /// Miscellaneous flags
	__le16  s_raid_stride;          /// RAID stride
	__le16  s_mmp_update_interval;  /// # seconds to wait in MMP checking
	__le64  s_mmp_block;            /// Block for multi-mount protection
	__le32  s_raid_stripe_width;    /// blocks on all data disks (N*stride)
	__u8    s_log_groups_per_flex;  /// FLEX_BG group size
	__u8    s_checksum_type;        /// metadata checksum algorithm used
	__le16  s_reserved_pad;
	__le64  s_kbytes_written;       /// nr of lifetime kilobytes written
	__le32  s_snapshot_inum;        /// Inode number of active snapshot
	__le32  s_snapshot_id;          /// sequential ID of active snapshot
	__le64  s_snapshot_r_blocks_count; /// reserved blocks for active snapshot's future use
	__le32  s_snapshot_list;        /// inode number of the head of the on-disk snapshot list
	__le32  s_error_count;          /// number of fs errors
	__le32  s_first_error_time;     /// first time an error happened
	__le32  s_first_error_ino;      /// inode involved in first error
	__le64  s_first_error_block;    /// block involved of first error
	__u8    s_first_error_func[32]; /// function where the error happened
	__le32  s_first_error_line;     /// line number where error happened
	__le32  s_last_error_time;      /// most recent time of an error
	__le32  s_last_error_ino;       /// inode involved in last error
	__le32  s_last_error_line;      /// line number where error happened
	__le64  s_last_error_block;     /// block involved of last error
	__u8    s_last_error_func[32];  /// function where the error happened
	__u8    s_mount_opts[64];
	__le32  s_usr_quota_inum;       /// inode for tracking user quota
	__le32  s_grp_quota_inum;       /// inode for tracking group quota
	__le32  s_overhead_clusters;    /// overhead blocks/clusters in fs
	__le32  s_reserved[108];        /// Padding to the end of the block
	__le32  s_checksum;             /// crc32c(superblock)

	@property __le16 desc_size() const pure nothrow
	{
		return s_feature_incompat_64bit ? s_desc_size : 32;
	}
}

enum EXT4_S_ERR_START = ext4_super_block.s_error_count.offsetof;
enum EXT4_S_ERR_END   = ext4_super_block.s_mount_opts.offsetof;

///
enum EXT4_NAME_LEN = 255;

/// Structure of a directory entry
struct ext4_dir_entry
{
	__le32  inode;                  /* Inode number */
	__le16  rec_len;                /* Directory entry length */
	__le16  name_len;               /* Name length */
	char    name[EXT4_NAME_LEN];    /* File name */
}

/**
 The new version of the directory entry.  Since EXT4 structures are
 stored in intel byte order, and the name_len field could never be
 bigger than 255 chars, it's safe to reclaim the extra byte for the
 file_type field.
*/
struct ext4_dir_entry_2
{
	__le32  inode;                  /// Inode number
	__le16  rec_len;                /// Directory entry length
	__u8    name_len;               /// Name length
	__u8    file_type;              /// File type
	char    name[EXT4_NAME_LEN];    /// File name
}

/// Structure of a blocks group descriptor
struct ext4_group_desc
{
	__le32  bg_block_bitmap_lo;      /// Blocks bitmap block
	__le32  bg_inode_bitmap_lo;      /// Inodes bitmap block
	__le32  bg_inode_table_lo;       /// Inodes table block
	__le16  bg_free_blocks_count_lo; /// Free blocks count
	__le16  bg_free_inodes_count_lo; /// Free inodes count
	__le16  bg_used_dirs_count_lo;   /// Directories count
	__le16  bg_flags;                /// EXT4_BG_flags (INODE_UNINIT, etc)
	__le32  bg_exclude_bitmap_lo;    /// Exclude bitmap for snapshots
	__le16  bg_block_bitmap_csum_lo; /// crc32c(s_uuid+grp_num+bbitmap) LE
	__le16  bg_inode_bitmap_csum_lo; /// crc32c(s_uuid+grp_num+ibitmap) LE
	__le16  bg_itable_unused_lo;     /// Unused inodes count
	__le16  bg_checksum;             /// crc16(sb_uuid+group+desc)
	__le32  bg_block_bitmap_hi;      /// Blocks bitmap block MSB
	__le32  bg_inode_bitmap_hi;      /// Inodes bitmap block MSB
	__le32  bg_inode_table_hi;       /// Inodes table block MSB
	__le16  bg_free_blocks_count_hi; /// Free blocks count MSB
	__le16  bg_free_inodes_count_hi; /// Free inodes count MSB
	__le16  bg_used_dirs_count_hi;   /// Directories count MSB
	__le16  bg_itable_unused_hi;     /// Unused inodes count MSB
	__le32  bg_exclude_bitmap_hi;    /// Exclude bitmap block MSB
	__le16  bg_block_bitmap_csum_hi; /// crc32c(s_uuid+grp_num+bbitmap) BE
	__le16  bg_inode_bitmap_csum_hi; /// crc32c(s_uuid+grp_num+ibitmap) BE
	__u32   bg_reserved;
}

///
enum
{
	EXT4_NDIR_BLOCKS = 12,
	EXT4_IND_BLOCK   = EXT4_NDIR_BLOCKS,
	EXT4_DIND_BLOCK  = (EXT4_IND_BLOCK + 1),
	EXT4_TIND_BLOCK  = (EXT4_DIND_BLOCK + 1),
	EXT4_N_BLOCKS    = (EXT4_TIND_BLOCK + 1),
}

enum FileType : uint
{
	fifo = 1,
	chrdev = 2,
	dir = 4,
	blkdev = 6,
	reg = 8,
	link = 10,
	socket = 12
}

struct Mode
{
	union
	{
		mixin(bitfields!(
			uint, "perm", 9,
			bool, "sticky", 1,
			bool, "setguid", 1,
			bool, "setuid", 1,
			FileType, "type", 4));
		__u16 mode;
	}

	void toString(scope void delegate(const(char)[]) sink) const
	{
		switch (type)
		{
		case FileType.fifo:
			sink("FIFO"); break;
		case FileType.chrdev:
			sink("CDEV"); break;
		case FileType.blkdev:
			sink("BDEV"); break;
		case FileType.reg:
			sink("FILE"); break;
		case FileType.link:
			sink("LINK"); break;
		case FileType.dir:
			sink("DIR "); break;
		case FileType.socket:
			sink("SOCK"); break;
		default:
			sink("????"); break;
		}
		sink(" | ");
		char[3] pp;
		pp[0] = ((perm >> 6) & 7) + '0';
		pp[1] = ((perm >> 3) & 7) + '0';
		pp[2] = ((perm >> 0) & 7) + '0';
		sink(pp[]);
		if (sticky)
			sink(" | sticky");
		if (setguid)
			sink(" | setguid");
		if (setuid)
			sink(" | setuid");
	}
}

///
struct ext4_inode
{
	__le16  i_mode;         /// File mode
	__le16  i_uid;          /// Low 16 bits of Owner Uid
	__le32  i_size_lo;      /// Size in bytes
	__le32  i_atime;        /// Access time
	__le32  i_ctime;        /// Inode Change time
	__le32  i_mtime;        /// Modification time
	__le32  i_dtime;        /// Deletion Time
	__le16  i_gid;          /// Low 16 bits of Group Id
	__le16  i_links_count;  /// Links count
	__le32  i_blocks_lo;    /// Blocks count
	__le32  i_flags;        /// File flags
	__le32  l_i_version;    ///
	union
	{
		__le32  i_block[EXT4_N_BLOCKS]; /// Pointers to blocks
		struct
		{
			ext4_extent_header extent_header;
			union
			{
				ext4_extent extent[4];
				ext4_extent_idx extent_idx[4];
			}
		}
	}
	__le32  i_generation;   /// File version (for NFS)
	__le32  i_file_acl_lo;  /// File ACL
	__le32  i_size_high;    ///
	__le32  i_obso_faddr;   /// Obsoleted fragment address
	__le16  l_i_blocks_high; /// were l_i_reserved1
	__le16  l_i_file_acl_high; ///
	__le16  l_i_uid_high;   /// these 2 fields were reserved2[0]
	__le16  l_i_gid_high;   /// ditto
	__le16  l_i_checksum_lo; /// crc32c(uuid+inum+inode) LE
	__le16  l_i_reserved;   ///
	__le16  i_extra_isize;  ///
	__le16  i_checksum_hi;  /// crc32c(uuid+inum+inode) BE
	__le32  i_ctime_extra;  /// extra Change time      (nsec << 2 | epoch)
	__le32  i_mtime_extra;  /// extra Modification time(nsec << 2 | epoch)
	__le32  i_atime_extra;  /// extra Access time      (nsec << 2 | epoch)
	__le32  i_crtime;       /// File Creation time
	__le32  i_crtime_extra; /// extra FileCreationtime (nsec << 2 | epoch)
	__le32  i_version_hi;   /// high 32 bits for 64-bit version

	@property Mode mode() const pure nothrow
	{
		Mode m;
		m.mode = i_mode;
		return m;
	}

	@property ulong size() const pure nothrow
	{
		if (mode.type == FileType.reg)
			return bitCat(i_size_high, i_size_lo);
		else
			return i_size_lo;
	}
}

enum EXT4_EPOCH_BITS = 2;
enum EXT4_EPOCH_MASK = (1UL << EXT4_EPOCH_BITS) - 1;
enum EXT4_NSEC_MASK  = (~0UL << EXT4_EPOCH_BITS);

/// This is the extent on-disk structure. It's used at the bottom of the tree.
struct ext4_extent
{
	__le32  ee_block;       /// first logical block extent covers
	__le16  ee_len;         /// number of blocks covered by extent
	__le16  ee_start_hi;    /// high 16 bits of physical block
	__le32  ee_start_lo;    /// low 32 bits of physical block
};

/// This is index on-disk structure. It's used at all the levels except the bottom.
struct ext4_extent_idx
{
	__le32  ei_block;       /// index covers logical blocks from 'block'
	__le32  ei_leaf_lo;     /// pointer to the physical block of the next level. leaf or next index could be there
	__le16  ei_leaf_hi;     /// high 16 bits of physical block
	__u16   ei_unused;
};

/// Each block (leaves and indexes), even inode-stored has header.
struct ext4_extent_header
{
	__le16  eh_magic;       /// probably will support different formats
	__le16  eh_entries;     /// number of valid entries
	__le16  eh_max;         /// capacity of store in entries
	__le16  eh_depth;       /// has tree real underlying blocks?
	__le32  eh_generation;  /// generation of the tree
};

static assert(ext4_extent.sizeof == ext4_extent_idx.sizeof);
static assert(ext4_extent.sizeof == ext4_extent_header.sizeof);

///
enum __le16 EXT4_EXT_MAGIC = 0xf30a;
