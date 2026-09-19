#import <Foundation/Foundation.h>

// File is safe for UI/playback lookups: immutable mapping + bounded filesystem attributes,
// no directory scan or content hashing. All other functions run on the serial worker.
// A private hash.ext -> Documents-relative path mapping also covers older manual imports.
// Unknown/missing mappings fall back to Spoti Downloads/hash.ext; hashes are never aliased.
FOUNDATION_EXPORT NSURL *SGAutomaticLibraryFile(NSDictionary *row);
// Call only after the caller verified the complete digest and committed installation.
FOUNDATION_EXPORT void SGAutomaticLibraryRegister(NSDictionary *verifiedRow, NSURL *file);

// Reuses an existing verified file only for identical full bytes, or identical encoded
// audio/format + exact title/artist/album + duration (including the local-URI second).
// Returns requested enriched with the keeper's actual ready fields, or nil. It does not
// move/delete prepared and will not replace artwork with a keeper lacking artwork.
// prepared=nil is an exact requested id+bytes lookup only (no packet equivalence).
FOUNDATION_EXPORT NSDictionary *SGAutomaticLibraryReuse(NSURL *prepared, NSDictionary *requested, BOOL (^cancelled)(void));

// Run on the serial worker. Immutable display snapshots contain path (relative to
// Documents), title, artist, album, bytes, extension and a private stat stamp.
// Listing reads metadata only: no full-file or packet hashing. Cancellation returns [].
FOUNDATION_EXPORT NSArray<NSDictionary *> *SGAutomaticLibraryItems(BOOL (^cancelled)(void));

// Permanently deletes only the selected physical file after checking its saved stamp.
// The caller obtains user confirmation. Stale entries, links and directories fail;
// an identical copy at another path remains untouched. Run on the serial worker.
FOUNDATION_EXPORT BOOL SGAutomaticLibraryDelete(NSDictionary *item, NSError **error);
