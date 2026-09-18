#import "Protobuf.h"
// Move one unambiguous artists shelf immediately before the play shelf.
// Unknown/partial/ambiguous feeds are left untouched.
BOOL SGHomeOrderShelves(NSMutableArray<SGPBField *> *sections);
