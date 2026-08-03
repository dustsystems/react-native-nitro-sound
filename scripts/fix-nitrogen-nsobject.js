// scripts/fix-nitrogen-nsobject.js
const fs = require('fs');
const path = require('path');

// ============================================
// Fix 1: NSObject inheritance for HybridSoundSpec.swift
// ============================================
const swiftFilePath = path.join(
  __dirname,
  '../nitrogen/generated/ios/swift/HybridSoundSpec.swift'
);

function fixNSObjectInheritance() {
  if (!fs.existsSync(swiftFilePath)) {
    console.log('⚠️  HybridSoundSpec.swift not found - might not be generated yet');
    return;
  }

  let content = fs.readFileSync(swiftFilePath, 'utf8');

  if (content.includes('HybridSoundSpec_base: NSObject')) {
    console.log('✅ NSObject inheritance already fixed');
    return;
  }

  content = content.replace(
    'open class HybridSoundSpec_base {',
    'open class HybridSoundSpec_base: NSObject {'
  );

  content = content.replace(
    'public init() { }',
    'public override init() { super.init() }'
  );

  fs.writeFileSync(swiftFilePath, content);

  console.log('✅ Fixed NSObject inheritance in HybridSoundSpec.swift');
  console.log('   - Added NSObject inheritance to HybridSoundSpec_base');
  console.log('   - Fixed init() to call super.init()');
}

// ============================================
// Fix 2: Replace NON_NULL with _Nonnull in generated C++ files
// (nitrogen 0.29.6 generates NON_NULL but nitro-modules 0.29.6 doesn't define it)
// ============================================
const iosGeneratedDir = path.join(__dirname, '../nitrogen/generated/ios');

function fixNonNullMacro() {
  if (!fs.existsSync(iosGeneratedDir)) {
    console.log('⚠️  nitrogen/generated/ios/ not found - might not be generated yet');
    return;
  }

  const filesToFix = [];

  // Find all .hpp and .cpp files recursively
  function findFiles(dir) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        findFiles(fullPath);
      } else if (entry.name.endsWith('.hpp') || entry.name.endsWith('.cpp')) {
        filesToFix.push(fullPath);
      }
    }
  }

  findFiles(iosGeneratedDir);

  let fixedCount = 0;
  for (const filePath of filesToFix) {
    let content = fs.readFileSync(filePath, 'utf8');

    if (content.includes('NON_NULL')) {
      content = content.replace(/NON_NULL/g, '_Nonnull');
      fs.writeFileSync(filePath, content);
      fixedCount++;
    }
  }

  if (fixedCount > 0) {
    console.log(`✅ Fixed NON_NULL → _Nonnull in ${fixedCount} file(s)`);
  } else {
    console.log('✅ No NON_NULL macros found (already using _Nonnull)');
  }
}

// ============================================
// Run all fixes
// ============================================
try {
  fixNSObjectInheritance();
  fixNonNullMacro();
} catch (error) {
  console.error('❌ Error during nitrogen fixes:', error.message);
  process.exit(1);
}
