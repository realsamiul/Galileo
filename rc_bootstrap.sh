#!/bin/bash
set -euo pipefail

echo "=== RoosCloset Bootstrap ==="
export AWS_DEFAULT_REGION=us-west-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID | Region: $AWS_DEFAULT_REGION"

echo "Installing Node 18..."
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs 2>/dev/null || true
node --version

npm install -g aws-cdk
cdk --version

mkdir -p ~/rooscloset/{atlas/handlers,atlas/schema,mirror/handlers,cdk/lib,cdk/bin}
cd ~/rooscloset/cdk

cat > package.json << 'EOF'
{
  "name": "rooscloset-cdk",
  "version": "1.0.0",
  "bin": { "app": "bin/app.js" },
  "scripts": { "build": "tsc", "cdk": "cdk" },
  "dependencies": {
    "aws-cdk-lib": "^2.150.0",
    "constructs": "^10.3.0",
    "source-map-support": "^0.5.21"
  },
  "devDependencies": {
    "typescript": "~5.4.0",
    "@types/node": "^20.0.0",
    "ts-node": "^10.9.2"
  }
}
EOF

cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "lib": ["es2020"],
    "declaration": true,
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "noImplicitThis": true,
    "alwaysStrict": true,
    "outDir": "./dist",
    "rootDir": ".",
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["bin/**/*", "lib/**/*"]
}
EOF

cat > cdk.json << 'EOF'
{ "app": "npx ts-node bin/app.ts" }
EOF

echo "Installing CDK dependencies..."
npm install

echo "=== Bootstrap complete. Run rc_sources.sh next. ==="