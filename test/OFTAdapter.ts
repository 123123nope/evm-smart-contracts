import {
    LBTCMock,
    EndpointV2Mock,
    LBTCOFTAdapter,
    LBTCBurnMintOFTAdapter,
} from '../typechain-types';
import {
    takeSnapshot,
    SnapshotRestorer,
} from '@nomicfoundation/hardhat-toolbox/network-helpers';
import {
    getSignersWithPrivateKeys,
    deployContract,
    encode,
    Signer,
} from './helpers';
import { ethers } from 'hardhat';
import { expect } from 'chai';
import { Options } from '@layerzerolabs/lz-v2-utilities';

describe('OFTAdapter', function () {
    let deployer: Signer, signer1: Signer, signer2: Signer, signer3: Signer;

    let lbtc: LBTCMock;
    let snapshot: SnapshotRestorer;

    const aEid = 1;
    const bEid = 2;

    let aOFTAdapter: LBTCOFTAdapter;
    let aBMOFTAdapter: LBTCBurnMintOFTAdapter;
    let bBMOFTAdapter: LBTCBurnMintOFTAdapter;
    let aLZEndpoint: EndpointV2Mock;
    let bLZEndpoint: EndpointV2Mock;

    before(async function () {
        [deployer, signer1, signer2, signer3] =
            await getSignersWithPrivateKeys();

        lbtc = await deployContract<LBTCMock>('LBTCMock', [
            ethers.ZeroAddress,
            100,
            deployer.address,
        ]);

        // deploy LayerZero endpoint
        aLZEndpoint = await deployContract<EndpointV2Mock>(
            'EndpointV2Mock',
            [aEid],
            false
        );
        bLZEndpoint = await deployContract<EndpointV2Mock>(
            'EndpointV2Mock',
            [bEid],
            false
        );

        aBMOFTAdapter = await deployContract<LBTCBurnMintOFTAdapter>(
            'LBTCBurnMintOFTAdapter',
            [
                await lbtc.getAddress(),
                await aLZEndpoint.getAddress(),
                deployer.address,
            ],
            false
        );
        await lbtc.addMinter(await aBMOFTAdapter.getAddress());

        aOFTAdapter = await deployContract<LBTCOFTAdapter>(
            'LBTCOFTAdapter',
            [
                await lbtc.getAddress(),
                await aLZEndpoint.getAddress(),
                deployer.address,
            ],
            false
        );

        bBMOFTAdapter = await deployContract<LBTCBurnMintOFTAdapter>(
            'LBTCBurnMintOFTAdapter',
            [
                await lbtc.getAddress(),
                await bLZEndpoint.getAddress(),
                deployer.address,
            ],
            false
        );
        await lbtc.addMinter(await bBMOFTAdapter.getAddress());

        await aOFTAdapter.setPeer(
            bEid,
            encode(['address'], [await bBMOFTAdapter.getAddress()])
        );
        await bBMOFTAdapter.setPeer(
            aEid,
            encode(['address'], [await aOFTAdapter.getAddress()])
        );

        await aLZEndpoint.setDestLzEndpoint(
            await bBMOFTAdapter.getAddress(),
            await bLZEndpoint.getAddress()
        );
        await bLZEndpoint.setDestLzEndpoint(
            await aOFTAdapter.getAddress(),
            await aLZEndpoint.getAddress()
        );

        snapshot = await takeSnapshot();
    });

    describe('LBTCBurnMintOFTAdapter & LBTCOFTAdapter', function () {
        describe('should return result', function () {
            beforeEach(async function () {
                await snapshot.restore();
            });

            it('isPeer()', async () => {
                expect(
                    await aOFTAdapter.isPeer(
                        bEid,
                        encode(['address'], [await bBMOFTAdapter.getAddress()])
                    )
                ).eq(true);

                expect(
                    await bBMOFTAdapter.isPeer(
                        aEid,
                        encode(['address'], [await aOFTAdapter.getAddress()])
                    )
                ).eq(true);

                expect(
                    await aBMOFTAdapter.isPeer(
                        bEid,
                        encode(['address'], [await bBMOFTAdapter.getAddress()])
                    )
                ).eq(false);
            });

            it('peers()', async () => {
                expect(await aOFTAdapter.peers(bEid)).eq(
                    encode(['address'], [await bBMOFTAdapter.getAddress()])
                );

                expect(await bBMOFTAdapter.peers(aEid)).eq(
                    encode(['address'], [await aOFTAdapter.getAddress()])
                );

                expect(await aBMOFTAdapter.peers(bEid)).eq(
                    encode(['address'], [ethers.ZeroAddress])
                );
            });

            it('pause()', async () => {
                expect(await aBMOFTAdapter.paused()).eq(false);
            });

            it('decimalConversionRate()', async () => {
                expect(await aBMOFTAdapter.decimalConversionRate()).eq(100);
            });

            it('owner()', async () => {
                expect(await aBMOFTAdapter.owner()).eq(deployer.address);
            });

            it('oAppVersion()', async () => {
                expect((await aBMOFTAdapter.oAppVersion()).toString()).to.be.eq(
                    [1n, 2n].toString()
                );
            });

            it('oftVersion()', async () => {
                expect((await aBMOFTAdapter.oftVersion()).toString()).to.be.eq(
                    ['0x02e49c2c', 1n].toString()
                );
            });

            it('sharedDecimals()', async () => {
                expect(await aBMOFTAdapter.sharedDecimals()).eq(6n);
            });

            it('approvalRequired()', async () => {
                expect(await aBMOFTAdapter.approvalRequired()).eq(true);
            });

            it('endpoint()', async () => {
                expect(await aBMOFTAdapter.endpoint()).eq(
                    await aLZEndpoint.getAddress()
                );
            });

            it('quoteSend()', async () => {
                const opts = Options.newOptions().addExecutorLzReceiveOption(
                    100_000,
                    0
                );
                const msgFee = await aOFTAdapter.quoteSend(
                    {
                        dstEid: bEid,
                        to: encode(['address'], [signer1.address]),
                        amountLD: '100',
                        minAmountLD: '100',
                        extraOptions: opts.toHex(),
                        composeMsg: '0x',
                        oftCmd: '0x',
                    },
                    false
                );

                expect(msgFee.lzTokenFee).eq(0);
                expect(msgFee.nativeFee).eq(2102_6400_0000_0000n);
            });

            it('quoteOFT()', async () => {
                const opts = Options.newOptions().addExecutorLzReceiveOption(
                    100_000,
                    0
                );
                const amountLD = 100n;
                const { oftLimit, oftFeeDetails, oftReceipt } =
                    await aOFTAdapter.quoteOFT({
                        dstEid: bEid,
                        to: encode(['address'], [signer1.address]),
                        amountLD: amountLD,
                        minAmountLD: amountLD,
                        extraOptions: opts.toHex(),
                        composeMsg: '0x',
                        oftCmd: '0x',
                    });

                expect(oftLimit.minAmountLD).eq(0n);
                expect(oftLimit.maxAmountLD).eq(2n ** 64n - 1n); // check sharedDecimals() description for details

                expect(oftFeeDetails).length(0);

                expect(oftReceipt.amountReceivedLD).eq(amountLD);
                expect(oftReceipt.amountSentLD).eq(amountLD);
            });
        });

        it('should lock (Chain A) and mint (Chain B)', async () => {
            const amountLD = 200n;

            await lbtc.mintTo(signer1.address, amountLD);

            const opts = Options.newOptions().addExecutorLzReceiveOption(
                100_000,
                0
            );

            const args = {
                dstEid: bEid,
                to: encode(['address'], [signer2.address]),
                amountLD: amountLD,
                minAmountLD: amountLD,
                extraOptions: opts.toHex(),
                composeMsg: '0x',
                oftCmd: '0x',
            };

            const msgFee = await aOFTAdapter.quoteSend(args, false);

            const totalSupplyBefore = await lbtc.totalSupply();

            await lbtc
                .connect(signer1)
                .approve(await aOFTAdapter.getAddress(), amountLD);

            const tx = await aOFTAdapter.connect(signer1).send(
                args,
                {
                    nativeFee: msgFee.nativeFee,
                    lzTokenFee: msgFee.lzTokenFee,
                },
                signer3.address,
                {
                    value: msgFee.nativeFee,
                }
            );

            // fees paid
            await expect(tx).changeEtherBalances(
                [signer1, signer3],
                [msgFee.nativeFee * -1n, 0]
            );

            await expect(tx).changeTokenBalances(
                lbtc,
                [signer1, signer2, aOFTAdapter, bBMOFTAdapter],
                [amountLD * -1n, amountLD, amountLD, 0]
            );

            const totalSupplyAfter = await lbtc.totalSupply();

            // supply was increased, because deposit was locked, and withdrawal was minted
            expect(totalSupplyAfter).gt(totalSupplyBefore);
        });

        it('should burn (Chain B) and unlock (Chain A)', async () => {
            const amountLD = 100n;

            const totalSupplyBefore = await lbtc.totalSupply();

            const opts = Options.newOptions().addExecutorLzReceiveOption(
                200_000,
                0
            );

            const args = {
                dstEid: aEid,
                to: encode(['address'], [signer1.address]),
                amountLD: amountLD,
                minAmountLD: amountLD,
                extraOptions: opts.toHex(),
                composeMsg: '0x',
                oftCmd: '0x',
            };

            const msgFee = await bBMOFTAdapter.quoteSend(args, false);

            const tx = await bBMOFTAdapter.connect(signer2).send(
                args,
                {
                    nativeFee: msgFee.nativeFee,
                    lzTokenFee: msgFee.lzTokenFee,
                },
                signer3.address,
                {
                    value: msgFee.nativeFee,
                }
            );

            await expect(tx).changeEtherBalances(
                [signer2, signer3],
                [msgFee.nativeFee * -1n, 0]
            );

            await expect(tx).changeTokenBalances(
                lbtc,
                [signer2, signer1, aOFTAdapter, bBMOFTAdapter],
                [amountLD * -1n, amountLD, amountLD * -1n, 0]
            );

            const totalSupplyAfter = await lbtc.totalSupply();
            expect(totalSupplyAfter).lt(totalSupplyBefore);
        });

        it('should revert halt() when not paused', async () => {
            await expect(aOFTAdapter.halt()).to.be.revertedWithCustomError(
                aOFTAdapter,
                'ExpectedPause'
            );
        });

        it('migrate Chain A to MintBurnOFTAdapter', async () => {
            await expect(aOFTAdapter.pause()).to.emit(aOFTAdapter, 'Paused');
            await expect(bBMOFTAdapter.pause()).to.emit(
                bBMOFTAdapter,
                'Paused'
            );

            const totalSupplyBefore = await lbtc.totalSupply();
            const adapterBalanceBefore = await lbtc.balanceOf(aOFTAdapter);
            const haltTx = aOFTAdapter.halt();
            await expect(haltTx).changeTokenBalance(
                lbtc,
                aOFTAdapter,
                adapterBalanceBefore * -1n
            );
            const totalSupplyAfter = await lbtc.totalSupply();

            expect(totalSupplyAfter).lt(totalSupplyBefore);

            await bBMOFTAdapter.setPeer(
                aEid,
                encode(['address'], [await aBMOFTAdapter.getAddress()])
            );
            await aBMOFTAdapter.setPeer(
                bEid,
                encode(['address'], [await bBMOFTAdapter.getAddress()])
            );

            await bLZEndpoint.setDestLzEndpoint(
                await aBMOFTAdapter.getAddress(),
                await aLZEndpoint.getAddress()
            );

            await expect(bBMOFTAdapter.unpause()).to.emit(
                bBMOFTAdapter,
                'Unpaused'
            );
        });

        it('should burn (Chain B) and mint (Chain A)', async () => {
            const amountLD = 100n;

            const opts = Options.newOptions().addExecutorLzReceiveOption(
                300_000,
                0
            );

            const args = {
                dstEid: aEid,
                to: encode(['address'], [signer1.address]),
                amountLD: amountLD,
                minAmountLD: amountLD,
                extraOptions: opts.toHex(),
                composeMsg: '0x',
                oftCmd: '0x',
            };

            const msgFee = await bBMOFTAdapter.quoteSend(args, false);

            const totalSupplyBefore = await lbtc.totalSupply();

            const tx = await bBMOFTAdapter.connect(signer2).send(
                args,
                {
                    nativeFee: msgFee.nativeFee,
                    lzTokenFee: msgFee.lzTokenFee,
                },
                signer3.address,
                {
                    value: msgFee.nativeFee,
                }
            );

            await expect(tx).changeEtherBalances(
                [signer2, signer3],
                [msgFee.nativeFee * -1n, 0]
            );

            await expect(tx).changeTokenBalances(
                lbtc,
                [signer2, signer1, aBMOFTAdapter, bBMOFTAdapter],
                [amountLD * -1n, amountLD, 0, 0]
            );

            const totalSupplyAfter = await lbtc.totalSupply();
            expect(totalSupplyAfter).eq(totalSupplyBefore);
        });

        it('should burn (Chain A) and mint (Chain B)', async () => {
            const amountLD = 1_0000n;

            await lbtc.mintTo(signer1.address, amountLD);

            const opts = Options.newOptions().addExecutorLzReceiveOption(
                50_000,
                0
            );

            const args = {
                dstEid: bEid,
                to: encode(['address'], [signer2.address]),
                amountLD: amountLD,
                minAmountLD: amountLD,
                extraOptions: opts.toHex(),
                composeMsg: '0x',
                oftCmd: '0x',
            };

            const msgFee = await aBMOFTAdapter.quoteSend(args, false);

            const totalSupplyBefore = await lbtc.totalSupply();

            const tx = await aBMOFTAdapter.connect(signer1).send(
                args,
                {
                    nativeFee: msgFee.nativeFee,
                    lzTokenFee: msgFee.lzTokenFee,
                },
                signer3.address,
                {
                    value: msgFee.nativeFee,
                }
            );

            // fees paid
            await expect(tx).changeEtherBalances(
                [signer1, signer3],
                [msgFee.nativeFee * -1n, 0]
            );

            await expect(tx).changeTokenBalances(
                lbtc,
                [signer1, signer2, aBMOFTAdapter, bBMOFTAdapter],
                [amountLD * -1n, amountLD, 0, 0]
            );

            const totalSupplyAfter = await lbtc.totalSupply();
            expect(totalSupplyAfter).eq(totalSupplyBefore);
        });

        describe('should revert when paused', function () {
            const AMOUNT = 1_0000_0000;
            const OPTS = Options.newOptions().addExecutorLzReceiveOption(
                1_000_000,
                0
            );

            beforeEach(async function () {
                await snapshot.restore();
                await aOFTAdapter.pause();
                await bBMOFTAdapter.pause();
                await lbtc.mintTo(signer1.address, AMOUNT);
            });

            it('LBTCOFTAdapter::send()', async () => {
                const args = {
                    dstEid: bEid,
                    to: encode(['address'], [signer2.address]),
                    amountLD: AMOUNT,
                    minAmountLD: AMOUNT,
                    extraOptions: OPTS.toHex(),
                    composeMsg: '0x',
                    oftCmd: '0x',
                };

                const msgFee = await aOFTAdapter.quoteSend(args, false);

                await lbtc
                    .connect(signer1)
                    .approve(await aOFTAdapter.getAddress(), AMOUNT);

                await expect(
                    aOFTAdapter.connect(signer1).send(
                        args,
                        {
                            nativeFee: msgFee.nativeFee,
                            lzTokenFee: msgFee.lzTokenFee,
                        },
                        signer3.address,
                        {
                            value: msgFee.nativeFee,
                        }
                    )
                ).to.be.revertedWithCustomError(aOFTAdapter, 'EnforcedPause');
            });

            it('LBTCBurnMintOFTAdapter::send()', async () => {
                const args = {
                    dstEid: aEid,
                    to: encode(['address'], [signer1.address]),
                    amountLD: AMOUNT,
                    minAmountLD: AMOUNT,
                    extraOptions: OPTS.toHex(),
                    composeMsg: '0x',
                    oftCmd: '0x',
                };

                const msgFee = await bBMOFTAdapter.quoteSend(args, false);

                await expect(
                    bBMOFTAdapter.connect(signer1).send(
                        args,
                        {
                            nativeFee: msgFee.nativeFee,
                            lzTokenFee: msgFee.lzTokenFee,
                        },
                        signer3.address,
                        {
                            value: msgFee.nativeFee,
                        }
                    )
                ).to.be.revertedWithCustomError(bBMOFTAdapter, 'EnforcedPause');
            });
        });
    });
});
