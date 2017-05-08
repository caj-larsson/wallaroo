# Alphabet

This is an example application that will count the number of "votes" sent for
each letter of the alphabet.

You will need a working [Wallaroo Python API](/book/python/intro.md).

## Running Alphabet

In a shell, start up the Metrics UI if you don't already have it running:

```bash
docker start mui
```

In a shell, set up a listener:

```bash
nc -l 127.0.0.1 7002 > alphabet.out
```

In another shell, export the current directory and `wallaroo.py` directories to `PYTHONPATH`:

```bash
export PYTHONPATH="$PYTHONPATH:.:../../../../machida"
```

Export the machida binary directory to `PATH`:

```bash
export PATH="$PATH:../../../../machida/build"
```

Run `machida` with `--application-module alphabet`.

```bash
machida --application-module alphabet --in 127.0.0.1:7010 --out 127.0.0.1:7002 \
  --metrics 127.0.0.1:5001 --control 127.0.0.1:6000 --data 127.0.0.1:6001 \
  --worker-name worker-name \
  --ponythreads=1
```

In a third shell, send some messages

```bash
../../../../giles/sender/sender --buffy 127.0.0.1:7010 --file votes.msg \
  --batch-size 5 --interval 100_000_000 --messages 150 --binary \
  --variable-size --repeat --ponythreads=1
```

The messages have a 32-bit big-endian integer that represents the message length, followed by a byte that represents the character that is being voted on, followed by a 32-bit big-endian integer that represents the number of votes received for that letter.  The output is a byte representing the character that is being voted on, followed by the total number of votes for that character. You can view the output file with a tool like `hexdump`.