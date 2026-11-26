param(
    [Parameter(Mandatory=$true)][string]$Key,
    [string]$LocalPayloadPath = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CryptoSource = @'

using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;

public static class AgyCrypto {
    private static readonly byte[] MAGIC = Encoding.ASCII.GetBytes("AGYENC01");

    private static void DeriveKeys(string masterKey, byte[] salt, out byte[] encKey, out byte[] macKey) {
        byte[] keyBytes = Encoding.UTF8.GetBytes(masterKey.Trim());
        using (var hmac1 = new HMACSHA256(keyBytes)) {
            byte[] info1 = new byte[salt.Length + 1];
            Buffer.BlockCopy(salt, 0, info1, 0, salt.Length);
            info1[salt.Length] = 0x01;
            encKey = hmac1.ComputeHash(info1);
        }
        using (var hmac2 = new HMACSHA256(keyBytes)) {
            byte[] info2 = new byte[salt.Length + 1];
            Buffer.BlockCopy(salt, 0, info2, 0, salt.Length);
            info2[salt.Length] = 0x02;
            macKey = hmac2.ComputeHash(info2);
        }
    }

    public static void EncryptFile(string inputPath, string outputPath, string masterKey) {
        byte[] plain = File.ReadAllBytes(inputPath);
        byte[] salt = new byte[16];
        byte[] iv = new byte[16];
        using (var rng = RandomNumberGenerator.Create()) {
            rng.GetBytes(salt);
            rng.GetBytes(iv);
        }

        byte[] encKey, macKey;
        DeriveKeys(masterKey, salt, out encKey, out macKey);

        byte[] cipher;
        using (var aes = Aes.Create()) {
            aes.KeySize = 256;
            aes.BlockSize = 128;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = encKey;
            aes.IV = iv;
            using (var enc = aes.CreateEncryptor()) {
                cipher = enc.TransformFinalBlock(plain, 0, plain.Length);
            }
        }

        // Encrypt-then-MAC over [MAGIC(8) + Salt(16) + IV(16) + Cipher]
        byte[] toSign = new byte[8 + 16 + 16 + cipher.Length];
        Buffer.BlockCopy(MAGIC, 0, toSign, 0, 8);
        Buffer.BlockCopy(salt, 0, toSign, 8, 16);
        Buffer.BlockCopy(iv, 0, toSign, 24, 16);
        Buffer.BlockCopy(cipher, 0, toSign, 40, cipher.Length);

        byte[] tag;
        using (var hmac = new HMACSHA256(macKey)) {
            tag = hmac.ComputeHash(toSign);
        }

        // Output layout: [MAGIC(8)] + [Salt(16)] + [IV(16)] + [HMAC(32)] + [Cipher]
        using (var fs = File.Create(outputPath)) {
            fs.Write(MAGIC, 0, 8);
            fs.Write(salt, 0, 16);
            fs.Write(iv, 0, 16);
            fs.Write(tag, 0, 32);
            fs.Write(cipher, 0, cipher.Length);
        }

        Array.Clear(encKey, 0, encKey.Length);
        Array.Clear(macKey, 0, macKey.Length);
    }

    public static void DecryptFile(string inputPath, string outputPath, string masterKey) {
        byte[] data = File.ReadAllBytes(inputPath);
        if (data.Length < 72) throw new InvalidDataException("加密数据包长度异常或已损坏。");

        for (int i = 0; i < 8; i++) {
            if (data[i] != MAGIC[i]) throw new InvalidDataException("加密文件头标识不匹配。");
        }

        byte[] salt = new byte[16];
        byte[] iv = new byte[16];
        byte[] expectedTag = new byte[32];
        int cipherLen = data.Length - 72;
        byte[] cipher = new byte[cipherLen];

        Buffer.BlockCopy(data, 8, salt, 0, 16);
        Buffer.BlockCopy(data, 24, iv, 0, 16);
        Buffer.BlockCopy(data, 40, expectedTag, 0, 32);
        Buffer.BlockCopy(data, 72, cipher, 0, cipherLen);

        byte[] encKey, macKey;
        DeriveKeys(masterKey, salt, out encKey, out macKey);

        byte[] toVerify = new byte[8 + 16 + 16 + cipherLen];
        Buffer.BlockCopy(MAGIC, 0, toVerify, 0, 8);
        Buffer.BlockCopy(salt, 0, toVerify, 8, 16);
        Buffer.BlockCopy(iv, 0, toVerify, 24, 16);
        Buffer.BlockCopy(cipher, 0, toVerify, 40, cipherLen);

        byte[] actualTag;
        using (var hmac = new HMACSHA256(macKey)) {
            actualTag = hmac.ComputeHash(toVerify);
        }

        int diff = 0;
        for (int i = 0; i < 32; i++) {
            diff |= (expectedTag[i] ^ actualTag[i]);
        }
        if (diff != 0) {
            Array.Clear(encKey, 0, encKey.Length);
            Array.Clear(macKey, 0, macKey.Length);
            throw new CryptographicException("HMAC 校验失败：解密密钥不正确或密文已被篡改！");
        }

        byte[] plain;
        using (var aes = Aes.Create()) {
            aes.KeySize = 256;
            aes.BlockSize = 128;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = encKey;
            aes.IV = iv;
            using (var dec = aes.CreateDecryptor()) {
                plain = dec.TransformFinalBlock(cipher, 0, cipherLen);
            }
        }

        File.WriteAllBytes(outputPath, plain);
        Array.Clear(encKey, 0, encKey.Length);
        Array.Clear(macKey, 0, macKey.Length);
    }
}

'@

if (-not ([System.Management.Automation.PSTypeName]'AgyCrypto').Type) {
    Add-Type -TypeDefinition $CryptoSource -Language CSharp
}

$WorkDir = Join-Path $env:TEMP ("agy_bootstrap_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

try {
    $EncFile = Join-Path $WorkDir "payload.enc"
    $ZipFile = Join-Path $WorkDir "payload.zip"
    $ExtractDir = Join-Path $WorkDir "bundle"

    if ($LocalPayloadPath -and (Test-Path $LocalPayloadPath)) {
        Copy-Item -Path $LocalPayloadPath -Destination $EncFile -Force
        Write-Host "[1/3] 已加载本地加密载荷：$LocalPayloadPath" -ForegroundColor Cyan
    } else {
        Write-Host "[1/3] 正在免登录拉取 AES-256 加密同步包..." -ForegroundColor Cyan
        $ProxyUri = $null
        try {
            $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
            if ($ie -and $ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
                $ps = $ie.ProxyServer
                if ($ps -notmatch '^https?://') { $ps = "http://$ps" }
                $ProxyUri = $ps
            }
        } catch {}

        $Urls = @(
            "https://raw.githubusercontent.com/ZHANGKK-Z/Antigravity-Sync/main/payload.enc",
            "https://fastly.jsdelivr.net/gh/ZHANGKK-Z/Antigravity-Sync@main/payload.enc",
            "https://cdn.jsdelivr.net/gh/ZHANGKK-Z/Antigravity-Sync@main/payload.enc"
        )

        $Downloaded = $false
        foreach ($u in $Urls) {
            try {
                if ($ProxyUri -and $u -like "*githubusercontent*") {
                    Invoke-WebRequest -Uri $u -OutFile $EncFile -Proxy $ProxyUri -UseBasicParsing -TimeoutSec 20
                } else {
                    Invoke-WebRequest -Uri $u -OutFile $EncFile -UseBasicParsing -TimeoutSec 20
                }
                if ((Test-Path $EncFile) -and (Get-Item $EncFile).Length -gt 72) {
                    Write-Host "  -> 下载成功：$u ($([Math]::Round((Get-Item $EncFile).Length / 1024, 1)) KB)" -ForegroundColor Green
                    $Downloaded = $true
                    break
                }
            } catch {
                Write-Host "  -> 节点切换尝试中 ($u)..." -ForegroundColor Gray
            }
        }

        if (-not $Downloaded) {
            throw "无法从 GitHub Raw 或 CDN 节点下载 payload.enc，请确认仓库已设为 Public 或检查网络连接。"
        }
    }

    Write-Host "[2/3] 正在校验 HMAC-SHA256 签名并执行 AES-256 本地解密..." -ForegroundColor Cyan
    [AgyCrypto]::DecryptFile($EncFile, $ZipFile, $Key)
    Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force
    Write-Host "  -> 签名校验与解密成功！" -ForegroundColor Green

    Write-Host "[3/3] 正在执行全套规则、插件、AI-Memory 与深度汉化一键安装..." -ForegroundColor Cyan
    $DeployScript = Join-Path $ExtractDir "scripts\deploy.ps1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $DeployScript -SkipPause
} finally {
    # 无论成功失败，彻底擦除临时解密目录，不在 %TEMP% 残留任何明文副本
    if (Test-Path $WorkDir) {
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
