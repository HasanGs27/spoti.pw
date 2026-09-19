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

// Archives proven duplicates outside Documents, preserving a crash-recoverable journal.
// progress receives short French status strings. Results contain archived/restored/skipped,
// replacements and message. Cancellation preserves completed individual operations.
FOUNDATION_EXPORT NSDictionary *SGAutomaticLibraryClean(BOOL (^cancelled)(void), void (^progress)(NSString *message));
FOUNDATION_EXPORT NSDictionary *SGAutomaticLibraryRestore(BOOL (^cancelled)(void), void (^progress)(NSString *message));

// Persisted, flattened oldHash.ext -> actual keeper fields (id, bytes, seconds, title,
// artist, album, extension). Apply to history/localRows after cleaning and on startup.
// Restoration keeps these references valid and never removes/replaces the keeper.
FOUNDATION_EXPORT NSDictionary *SGAutomaticLibraryReplacements(void);
