#!/usr/bin/env python3
"""
Database migration script to add image deduplication support.
Adds content_hash and embedding_cached columns to images table.
"""

import os
import sys

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from py.db import Base, _ENGINE, init_db
from sqlalchemy import inspect, text

def check_columns_exist():
    """Check if the new columns already exist."""
    inspector = inspect(_ENGINE)
    columns = [col['name'] for col in inspector.get_columns('images')]
    
    has_content_hash = 'content_hash' in columns
    has_embedding_cached = 'embedding_cached' in columns
    
    return has_content_hash, has_embedding_cached

def migrate_database():
    """Add new columns if they don't exist."""
    print("=" * 60)
    print("Image Deduplication Database Migration")
    print("=" * 60)
    
    # Check current state
    try:
        has_content_hash, has_embedding_cached = check_columns_exist()
    except Exception as e:
        print(f"\n❌ Error checking database: {e}")
        print("\nCreating tables from scratch...")
        init_db()
        print("✅ Database initialized")
        return
    
    print(f"\nCurrent state:")
    print(f"  - content_hash column: {'✅ exists' if has_content_hash else '❌ missing'}")
    print(f"  - embedding_cached column: {'✅ exists' if has_embedding_cached else '❌ missing'}")
    
    if has_content_hash and has_embedding_cached:
        print("\n✅ Database already up to date!")
        return
    
    # Apply migrations
    print("\n📝 Applying migrations...")
    
    with _ENGINE.begin() as conn:
        if not has_content_hash:
            print("  - Adding content_hash column...")
            conn.execute(text('ALTER TABLE images ADD COLUMN content_hash VARCHAR(64)'))
            conn.execute(text('CREATE INDEX idx_images_content_hash ON images(content_hash)'))
            print("    ✅ content_hash added")
        
        if not has_embedding_cached:
            print("  - Adding embedding_cached column...")
            conn.execute(text('ALTER TABLE images ADD COLUMN embedding_cached INTEGER DEFAULT 0'))
            print("    ✅ embedding_cached added")
    
    print("\n✅ Migration completed successfully!")
    print("\nNext steps:")
    print("  1. Restart the application")
    print("  2. Upload images to test deduplication")
    print("  3. Check logs for [DEDUP] messages")

if __name__ == '__main__':
    try:
        migrate_database()
    except Exception as e:
        print(f"\n❌ Migration failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
