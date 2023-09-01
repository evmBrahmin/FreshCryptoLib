//********************************************************************************************/
//  ___           _       ___               _         _    _ _
// | __| _ ___ __| |_    / __|_ _ _  _ _ __| |_ ___  | |  (_) |__
// | _| '_/ -_|_-< ' \  | (__| '_| || | '_ \  _/ _ \ | |__| | '_ \
// |_||_| \___/__/_||_|  \___|_|  \_, | .__/\__\___/ |____|_|_.__/
//                                |__/|_|
///* Copyright (C) 2022 - Renaud Dubois - This file is part of FCL (Fresh CryptoLib) project
///* License: This software is licensed under MIT License
///* This Code may be reused including license and copyright notice.
///* See LICENSE file at the root folder of the project.
///* FILE: FCL_elliptic.t.sol
///*
///*
///* DESCRIPTION: test file for ecdsa signature protocol
///*
//**************************************************************************************/
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@solidity/FCL_elliptic.sol";
import "@solidity/FCL_Webauthn.sol";
import "@solidity/fcl_ecdsa_precbytecode.sol"; //precomputation table associated to public key, generated by sage

//external implementation to bench
//import "@solidity/ECops.sol";
import "@external/Secp256r1.sol";
import "@external/Secp256r1_maxrobot.sol";
import "@external/ECops.sol";

//echo "itsakindofmagic" | sha256sum, used as a label to find precomputations inside bytecode
uint256 constant _MAGIC_ENCODING = 0x9a8295d6f225e4f07313e2e1440ab76e26d4c6ed2d1eb4cbaa84827c8b7caa8d;

// library elliptic solidity from orbs network
contract wrap_ecdsa_orbs {
    uint256 constant gx = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    uint256 constant gy = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    //curve order (number of points)
    uint256 constant n = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    function wrap_ecdsa_core(bytes32 message, uint256[2] calldata rs, uint256[2] calldata Q) public returns (bool) {
        if (rs[0] == 0 || rs[0] >= n || rs[1] == 0 || rs[1] >= n) {
            return false;
        }

        if (!FCL_Elliptic_ZZ.ecAff_isOnCurve(Q[0], Q[1])) {
            return false;
        }

        uint256 sInv = FCL_Elliptic_ZZ.FCL_nModInv(rs[1]);

        uint256 scalar_u = mulmod(uint256(message), sInv, n);
        uint256 scalar_v = mulmod(rs[0], sInv, n);
        uint256[2] memory P1;
        uint256[2] memory P2;
        (P1[0], P1[1]) = ECops.multiplyScalar(gx, gy, scalar_u);
        (P2[0], P2[1]) = ECops.multiplyScalar(Q[0], Q[1], scalar_v);

        uint256 x1;
        (x1,) = ECops.add(P1[0], P1[1], P2[0], P2[1]);
        assembly {
            x1 := addmod(x1, sub(n, calldataload(rs)), n)
        }
        //return true;
        return x1 == 0;
    }
}

// library from obvioustech
contract wrap_ecdsa_obvious {
    function wrap_ecdsa_core(bytes32 message, uint256[2] calldata rs, uint256[2] calldata Q) public returns (bool) {
        PassKeyId memory pass = PassKeyId(Q[0], Q[1], "unused");
        return Secp256r1.Verify(pass, rs[0], rs[1], uint256(message));
    }
}

// library from maxrobot
contract wrap_ecdsa_maxrobot {
    function wrap_ecdsa_core(bytes32 message, uint256[2] calldata rs, uint256[2] calldata Q) public returns (bool) {
        return Secp256r1_maxrobot.Verify(Q[0], Q[1], rs, uint256(message));
    }
}

// library FreshCryptoLib without precomputations
contract Wrap_ecdsa_FCL {
    function wrap_ecdsa_core(bytes32 message, uint256[2] calldata rs, uint256[2] calldata Q) public returns (bool) {
        return FCL_Elliptic_ZZ.ecdsa_verify(message, rs, Q);
    }

    constructor() {}
}

// library FreshCryptoLib with precomputations
contract Wrap_ecdsa_precal {
    address public precomputations;

    function wrap_ecdsa_core(bytes32 message, uint256[2] calldata rs) public returns (bool) {
        return FCL_Elliptic_ZZ.ecdsa_precomputed_verify(message, rs, precomputations);
    }

    constructor(address bytecode) {
        precomputations = bytecode;
    }
}

// library FreshCryptoLib with precomputations and memory hack
contract Wrap_ecdsa_precal_hackmem {
    uint256 public precomputations;

    //compute the coefficients for multibase exponentiation, then their wnaf representation
    //note that this function can be implemented in the front to reduce tx cost

    function wrap_ecdsa_core(bytes32 message, uint256[2] calldata rs) public returns (bool) {
        return FCL_Elliptic_ZZ.ecdsa_precomputed_hackmem(message, rs, precomputations);
    }

    //provide the offset of precomputations in the contract
    constructor(uint256 offset_bytecode) {
        precomputations = offset_bytecode;
    }

    function change_offset(uint256 new_offset) public {
        precomputations = new_offset;
    }

    function reveal(uint256 index) public returns (uint256[2] memory px) {
        uint256[2] memory px;
        bool flag = true;
        uint256 offset = precomputations + 64 * index;
        assembly {
            codecopy(px, offset, 64)
        }
        return px;
    }

    function autotest() public returns (bool) {
        uint256[2] memory px;
        bool flag = true;
        for (uint256 i = 1; i < 256; i++) {
            uint256 offset = precomputations + 64 * i;
            assembly {
                codecopy(px, offset, 64)
            }

            flag = flag && FCL_Elliptic_ZZ.ecAff_isOnCurve(px[0], px[1]);
        }
        return flag;
    }

    //this function is only here to ensure that the precomputation table stored in constant x is written in the bytecode
    function OverrideMe(uint256 input) public returns (bytes memory res) {
        return x;
    }
}

contract EcdsaTest is Test {
    //curve prime field modulus
    uint256 constant p = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF;
    //short weierstrass first coefficient
    uint256 constant a = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC;
    //short weierstrass second coefficient
    uint256 constant b = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B;
    //generating point affine coordinates
    uint256 constant gx = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    uint256 constant gy = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    //curve order (number of points)
    uint256 constant n = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    /* -2 mod p constant, used to speed up inversion and doubling (avoid negation)*/
    uint256 constant minus_2 = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFD;
    /* -2 mod n constant, used to speed up inversion*/
    uint256 constant minus_2modn = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC63254F;

    uint256 constant minus_1 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    uint256 constant _prec_address = 0xcaca;
    uint256 constant _hack_address = 0xd0d0;
    uint256 constant _hack_offset = 0x10000000;

    function uintToBytes(uint256 v) public pure returns (bytes32 ret) {
        if (v == 0) {
            ret = "0";
        } else {
            while (v > 0) {
                ret = bytes32(uint256(ret) / (2 ** 8));
                ret |= bytes32(((v % 10) + 48) * 2 ** (8 * 31));
                v /= 10;
            }
        }
        return ret;
    }

    function write_precalcsage(uint256 C0, uint256 C1) public {
        string memory line = "cd ../../sage/FCL_ecdsa_precompute;rm -f *json;sage -c 'C0=";
        line = string.concat(line, vm.toString(C0));
        line = string.concat(line, ";C1=");
        line = string.concat(line, vm.toString(C1));
        line = string.concat(
            line,
            ";load(\"FCL_ecdsa_precompute.sage\")' ;cp fcl_ecdsa_precbytecode.json ../../tests/WebAuthn_forge/test/vectors_sage/fcl_ecdsa_precbytecode.json;"
        );

        vm.writeLine("scriptz.sh", line);

        string[] memory inputs = new string[](2);

        inputs[0] = "bash";
        inputs[1] = "scriptz.sh";
        vm.ffi(inputs);
        vm.removeFile("scriptz.sh");
        console.log("precalc done");
    }

    function test_Invariant_edge() public {
        //choose Q=2P, then verify duplication is ok
        uint256[4] memory Q;
        (Q[0], Q[1], Q[2], Q[3]) = FCL_Elliptic_ZZ.ecZZ_Dbl(gx, gy, 1, 1);
        uint256[4] memory _4P;
        (_4P[0], _4P[1], _4P[2], _4P[3]) = FCL_Elliptic_ZZ.ecZZ_Dbl(Q[0], Q[1], Q[2], Q[3]);
        uint256 _4P_res1;

        (_4P_res1,) = FCL_Elliptic_ZZ.ecZZ_SetAff(_4P[0], _4P[1], _4P[2], _4P[3]);

        uint256 _4P_res2 = FCL_Elliptic_ZZ.ecZZ_mulmuladd_S_asm(gx, gy, 4, 0);
        assertEq(_4P_res1, _4P_res2);

        uint256[2] memory nQ;
        (nQ[0], nQ[1]) = FCL_Elliptic_ZZ.ecZZ_SetAff(Q[0], Q[1], Q[2], Q[3]);
        uint256 _4P_res3 = FCL_Elliptic_ZZ.ecZZ_mulmuladd_S_asm(nQ[0], nQ[1], 2, 1);

        assertEq(_4P_res1, _4P_res3);
    }

    function wychproof_keyload(string memory filename, bool expected)
        public
        returns (uint256[2] memory key, string memory deployData, uint256 numtests)
    {
        deployData = vm.readFile(filename);

        uint256 wx = vm.parseJsonUint(deployData, ".NumberOfTests");
        console.log("NumberOfTests:", wx);
        key[0] = vm.parseJsonUint(deployData, ".keyx");
        console.log("key_x:", key[0]);
        key[1] = vm.parseJsonUint(deployData, ".keyy");
        console.log("key_y:", key[1]);
        bool res = FCL_Elliptic_ZZ.ecAff_isOnCurve(key[0], key[1]);
        assertEq(res, true);
        write_precalcsage(key[0], key[1]);
        load_precalc();

        console.log("Is key on curve:", res);

        return (key, deployData, wx);
    }

    //load a single test vector
    function wychproof_vecload(string memory deployData, string memory snum)
        public
        returns (uint256[2] memory rs, uint256 message, string memory title)
    {
        title = string(vm.parseJson(deployData, string.concat(".test_", snum)));

        console.log("\n test:", snum, title);
        console.log("\n ||");

        rs[0] = vm.parseJsonUint(deployData, string.concat(".sigx_", snum));
        rs[1] = vm.parseJsonUint(deployData, string.concat(".sigy_", snum));
        message = vm.parseJsonUint(deployData, string.concat(".msg_", snum));
    }

    function wychproof_keynvecload(string memory deployData, string memory snum)
        public
        returns (uint256[2] memory publickey, uint256[2] memory rs, uint256 message, string memory title)
    {
        deployData = vm.readFile("test/vectors_wychproof/vec_sec256r1_edge.json");

        title = string(vm.parseJson(deployData, string.concat(".test_", snum)));

        console.log("\n test:", snum, title);
        console.log("\n ||");

        rs[0] = vm.parseJsonUint(deployData, string.concat(".sigx_", snum));
        rs[1] = vm.parseJsonUint(deployData, string.concat(".sigy_", snum));
        message = vm.parseJsonUint(deployData, string.concat(".msg_", snum));
        publickey[0] = vm.parseJsonUint(deployData, string.concat(".keyx_", snum));
        publickey[1] = vm.parseJsonUint(deployData, string.concat(".keyy_", snum));
    }

    //testing Wychproof vectors: valid edge vectors, all tests are expected to be true
    function Validation_Invariant_ecmulmuladd(string memory filename, bool valid_flag) public {
        string memory deployData;
        uint256[2] memory key;
        uint256 numtests;
        (key, deployData, numtests) = wychproof_keyload(filename, valid_flag);
        uint256[2] memory checkpointGasLeft;

        bool res = FCL_Elliptic_ZZ.ecAff_isOnCurve(key[0], key[1]);

        assertEq(res, true);

        uint256[2] memory rs;
        string memory title;
        string memory snum = "1";
        for (uint256 i = 1; i <= numtests; i++) {
            snum = vm.toString(i);
            uint256 message;
            (rs, message, title) = wychproof_vecload(deployData, snum);

            vm.prank(vm.addr(5));

            checkpointGasLeft[0] = gasleft();
            //wrap_ecdsa_orbs wrap = new wrap_ecdsa_orbs();
            //wrap_ecdsa_obvious wrap = new wrap_ecdsa_obvious();
            // wrap_ecdsa_maxrobot wrap = new wrap_ecdsa_maxrobot();
            Wrap_ecdsa_FCL wrap = new Wrap_ecdsa_FCL();
            checkpointGasLeft[1] = gasleft();
            console.log("deployment no prec:", checkpointGasLeft[0] - checkpointGasLeft[1] - 100);

            checkpointGasLeft[0] = gasleft();
            //  Wrap_ecdsa_interleaved wrap2=new Wrap_ecdsa_interleaved(address(uint160(_prec_address)));

            //Wrap_ecdsa_precal wrap2 = new Wrap_ecdsa_precal(address(uint160(_prec_address)));
            Wrap_ecdsa_precal_hackmem wrap2 = load_precalc_hackmem(address(uint160(_hack_address)));

            //Wrap_ecdsa_precal_hackmem wrap3=load_precalc_hackmem(address(uint160(_hack_address+_hack_offset)));
            //wrap2.change_offset(_hack_offset+wrap3.precomputations());

            checkpointGasLeft[1] = gasleft();
            //console.log("precomputations ", wrap2.precomputations());
            //console.log("autotest", wrap2.autotest());
            //console.log("reveal %x %x", wrap2.reveal(1)[0], wrap2.reveal(1)[1]);

            console.log("deployment with prec, (no table cost):", checkpointGasLeft[0] - checkpointGasLeft[1] - 100);

            console.log("message:", message);
            console.log("sigx:", rs[0]);
            console.log("sigy:", rs[1]);

            checkpointGasLeft[0] = gasleft();
            res = wrap.wrap_ecdsa_core(bytes32(message), rs, key);
            checkpointGasLeft[1] = gasleft();
            console.log("signature verif no prec:", checkpointGasLeft[0] - checkpointGasLeft[1] - 100);

            assertEq(res, valid_flag);

            checkpointGasLeft[0] = gasleft();
            res = wrap2.wrap_ecdsa_core(bytes32(message), rs);

            checkpointGasLeft[1] = gasleft();
            console.log("signature verif with prec:", checkpointGasLeft[0] - checkpointGasLeft[1] - 100);

            // ensure both implementations return the same result
            assertEq(res, valid_flag);
        }
    }

    //testing Wychproof vectors: valid edge vectors, all tests are expected to be false
    function test_batch_ecmulmuladd() public {
        string memory filename_valid = "test/vectors_wychproof/vec_sec256r1_valid.json";
        string memory filename_invalid = "test/vectors_wychproof/vec_sec256r1_invalid.json";
        Validation_Invariant_ecmulmuladd(filename_invalid, false); //test valid vectors, all assert shall be true
        Validation_Invariant_ecmulmuladd(filename_valid, true); //test valid vectors, all assert shall be true
    }

    //find the offset of precomputation table in the bytecode of the contract
    function find_offset(bytes memory bytecode, uint256 magic_value) public returns (uint256 offset) {
        uint256 read_value;
        uint256 offset;
        uint256 offset2;
        uint256 px; //x elliptic point
        uint256 py; //y elliptic point

        for (uint256 i = 0; i < bytecode.length; i += 1) {
            assembly {
                read_value := mload(add(bytecode, i))
            }
            if (read_value == magic_value) {
                offset = i - 32;
            }
        }

        //check precomputations are correct, all points on curve P256
        for (uint256 i = 1; i < 256; i++) {
            offset2 = offset + 64 * i;

            assembly {
                //  	extcodecopy(deployed, px, offset, 64)
                px := mload(add(bytecode, offset2))
                py := mload(add(bytecode, add(offset2, 32)))
            }

            assertEq(FCL_Elliptic_ZZ.ecAff_isOnCurve(px, py), true);
            //           console.log("read=",px[0]);
        }
        console.log("Offset correct");
        return offset;
    }

    //i_address: target address of deployed contract
    function load_precalc_hackmem(address i_address) public returns (Wrap_ecdsa_precal_hackmem) {
        string memory deployData = vm.readFile("test/vectors_sage/fcl_ecdsa_precbytecode.json");
        bytes memory prec = abi.decode(vm.parseJson(deployData, ".Bytecode"), (bytes));
        uint256 estimated_size = 12; //sizeof contract, to be estimated

        uint256 checkpointGasLeft;
        uint256 checkpointGasLeft2;

        bytes memory args = abi.encode(estimated_size);
        bytes memory bytecode = abi.encodePacked(vm.getDeployedCode("FCL_ecdsa.t.sol:Wrap_ecdsa_precal_hackmem"));
        //bytes memory bytecode = abi.encodePacked(vm.getCode("FCL_ecdsa.t.sol:Wrap_ecdsa_precal_hackmem"), args);

        estimated_size = bytecode.length;

        //bytecode = abi.encodePacked(vm.getCode("FCL_ecdsa.t.sol:Wrap_ecdsa_precal_hackmem"), estimated_size);
        // console.logBytes(bytecode);
        console.log("Found offset =", find_offset(bytecode, _MAGIC_ENCODING));
        bytecode = bytes.concat(bytecode, prec);
        console.log("size contract hackmem=", estimated_size);
        console.log("size contract+prec=", bytecode.length);
        //      console.logBytes(bytecode);

        checkpointGasLeft = gasleft();
        vm.etch(address(uint160(i_address)), bytecode); //todo : replace with create

        address deployed;
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), 1)
        }

        checkpointGasLeft2 = gasleft();
        console.log("deployment of precomputation cost:", checkpointGasLeft - checkpointGasLeft2 - 100);

        uint256[2] memory px; //pointer to an elliptic point

        //check precomputations are correct, all points on curve P256
        for (uint256 i = 1; i < 256; i++) {
            uint256 offset = estimated_size + 64 * i;
            assembly {
                //  	extcodecopy(deployed, px, offset, 64)
                extcodecopy(i_address, px, offset, 64)
            }

            assertEq(FCL_Elliptic_ZZ.ecAff_isOnCurve(px[0], px[1]), true);
            //           console.log("read=",px[0]);
        }

        console.log("all testoncurve: true");

        Wrap_ecdsa_precal_hackmem wrap2 = Wrap_ecdsa_precal_hackmem(i_address);

        wrap2.change_offset(estimated_size);

        console.log("size=", wrap2.precomputations());

        return wrap2;
    }

    function load_precalc() public returns (bool) {
        string memory deployData = vm.readFile("test/vectors_sage/fcl_ecdsa_precbytecode.json");
        bytes memory prec = abi.decode(vm.parseJson(deployData, ".Bytecode"), (bytes));
        address a_prec; //address of the precomputations bytecode contract
        a_prec = address(uint160(_prec_address));
        uint256 checkpointGasLeft;
        uint256 checkpointGasLeft2;

        checkpointGasLeft = gasleft();
        vm.etch(a_prec, prec); //todo : replace with create
        checkpointGasLeft2 = gasleft();
        console.log("deployment of precomputation cost:", checkpointGasLeft - checkpointGasLeft2 - 100);
        uint256[2] memory px; //pointer to an elliptic point

        //check precomputations are correct, all points on curve P256
        for (uint256 i = 1; i < 256; i++) {
            uint256 offset = 64 * i;
            assembly {
                extcodecopy(a_prec, px, offset, 64)
            }

            assertEq(FCL_Elliptic_ZZ.ecAff_isOnCurve(px[0], px[1]), true);
        }

        return true;
    }

    /**
     * @dev Computation of uG+vQ using Strauss-Shamir's trick, G basepoint, Q public key
     */
    function ecZZ_mulmuladd_S4(
        uint256 Q0,
        uint256 Q1, //affine rep for input point Q
        uint256 scalar_u,
        uint256 scalar_v
    ) internal returns (uint256 X) {
        uint256 zz;
        uint256 zzz;
        uint256 Y;
        uint256 index = 255;
        uint256[6] memory T;
        uint256 H0;
        uint256 H1;

        unchecked {
            if (scalar_u == 0 && scalar_v == 0) return 0;

            (H0, H1) = FCL_Elliptic_ZZ.ecAff_add(gx, gy, Q0, Q1); //will not work if Q=P, obvious forbidden private key

            assembly {
                for { let T4 := add(shl(1, and(shr(index, scalar_v), 1)), and(shr(index, scalar_u), 1)) } eq(T4, 0) {
                    index := sub(index, 1)
                    T4 := add(shl(1, and(shr(index, scalar_v), 1)), and(shr(index, scalar_u), 1))
                } {}
                zz := add(shl(1, and(shr(index, scalar_v), 1)), and(shr(index, scalar_u), 1))

                if eq(zz, 1) {
                    X := gx
                    Y := gy
                }
                if eq(zz, 2) {
                    X := Q0
                    Y := Q1
                }
                if eq(zz, 3) {
                    X := H0
                    Y := H1
                }

                index := sub(index, 1)
                zz := 1
                zzz := 1

                for {} gt(minus_1, index) { index := sub(index, 1) } {
                    // inlined EcZZ_Dbl
                    let T1 := mulmod(2, Y, p) //U = 2*Y1, y free
                    let T2 := mulmod(T1, T1, p) // V=U^2
                    let T3 := mulmod(X, T2, p) // S = X1*V
                    T1 := mulmod(T1, T2, p) // W=UV
                    let T4 := mulmod(3, mulmod(addmod(X, sub(p, zz), p), addmod(X, zz, p), p), p) //M=3*(X1-ZZ1)*(X1+ZZ1)
                    zzz := mulmod(T1, zzz, p) //zzz3=W*zzz1
                    zz := mulmod(T2, zz, p) //zz3=V*ZZ1, V free

                    X := addmod(mulmod(T4, T4, p), mulmod(minus_2, T3, p), p) //X3=M^2-2S
                    T2 := mulmod(T4, addmod(X, sub(p, T3), p), p) //-M(S-X3)=M(X3-S)
                    Y := addmod(mulmod(T1, Y, p), T2, p) //-Y3= W*Y1-M(S-X3), we replace Y by -Y to avoid a sub in ecAdd

                    {
                        //value of dibit
                        T4 := add(shl(1, and(shr(index, scalar_v), 1)), and(shr(index, scalar_u), 1))

                        if iszero(T4) {
                            Y := sub(p, Y) //restore the -Y inversion
                            continue
                        } // if T4!=0

                        if eq(T4, 1) {
                            T1 := gx
                            T2 := gy
                        }
                        if eq(T4, 2) {
                            T1 := Q0
                            T2 := Q1
                        }
                        if eq(T4, 3) {
                            T1 := H0
                            T2 := H1
                        }
                        if eq(zz, 0) {
                            X := T1
                            Y := T2
                            zz := 1
                            zzz := 1
                            continue
                        }
                        // inlined EcZZ_AddN

                        //T3:=sub(p, Y)
                        //T3:=Y
                        let y2 := addmod(mulmod(T2, zzz, p), Y, p) //R
                        T2 := addmod(mulmod(T1, zz, p), sub(p, X), p) //P

                        //special extremely rare case accumulator where EcAdd is replaced by EcDbl, no need to optimize this
                        //todo : construct edge vector case
                        if eq(y2, 0) {
                            if eq(T2, 0) {
                                T1 := mulmod(minus_2, Y, p) //U = 2*Y1, y free
                                T2 := mulmod(T1, T1, p) // V=U^2
                                T3 := mulmod(X, T2, p) // S = X1*V

                                let TT1 := mulmod(T1, T2, p) // W=UV
                                y2 := addmod(X, zz, p)
                                TT1 := addmod(X, sub(p, zz), p)
                                y2 := mulmod(y2, TT1, p) //(X-ZZ)(X+ZZ)
                                T4 := mulmod(3, y2, p) //M

                                zzz := mulmod(TT1, zzz, p) //zzz3=W*zzz1
                                zz := mulmod(T2, zz, p) //zz3=V*ZZ1, V free

                                X := addmod(mulmod(T4, T4, p), mulmod(minus_2, T3, p), p) //X3=M^2-2S
                                T2 := mulmod(T4, addmod(T3, sub(p, X), p), p) //M(S-X3)

                                Y := addmod(T2, mulmod(T1, Y, p), p) //Y3= M(S-X3)-W*Y1

                                continue
                            }
                        }

                        T4 := mulmod(T2, T2, p) //PP
                        let TT1 := mulmod(T4, T2, p) //PPP, this one could be spared, but adding this register spare gas
                        zz := mulmod(zz, T4, p)
                        zzz := mulmod(zzz, TT1, p) //zz3=V*ZZ1
                        let TT2 := mulmod(X, T4, p)
                        T4 := addmod(addmod(mulmod(y2, y2, p), sub(p, TT1), p), mulmod(minus_2, TT2, p), p)
                        Y := addmod(mulmod(addmod(TT2, sub(p, T4), p), y2, p), mulmod(Y, TT1, p), p)

                        X := T4
                    }
                } //end loop
                mstore(add(T, 0x60), zz)
                //(X,Y)=ecZZ_SetAff(X,Y,zz, zzz);
                //T[0] = inverseModp_Hard(T[0], p); //1/zzz, inline modular inversion using precompile:
                // Define length of base, exponent and modulus. 0x20 == 32 bytes
                mstore(T, 0x20)
                mstore(add(T, 0x20), 0x20)
                mstore(add(T, 0x40), 0x20)
                // Define variables base, exponent and modulus
                //mstore(add(pointer, 0x60), u)
                mstore(add(T, 0x80), minus_2)
                mstore(add(T, 0xa0), p)

                // Call the precompiled contract 0x05 = ModExp
                if iszero(call(not(0), 0x05, 0, T, 0xc0, T, 0x20)) { revert(0, 0) }

                //Y:=mulmod(Y,zzz,p)//Y/zzz
                //zz :=mulmod(zz, mload(T),p) //1/z
                //zz:= mulmod(zz,zz,p) //1/zz
                X := mulmod(X, mload(T), p) //X/zz
            } //end assembly
        } //end unchecked

        return X;
    }
}
