# Reverse

## About The Application

This is an example application that receives strings as input and outputs the reversed strings.

### Input

The inputs of the "Reverse" application are strings encoded in the [source message framing protocol](https://docs.wallaroolabs.com/book/appendix/tcp-decoders-and-encoders.html#framed-message-protocols#source-message-framing-protocol). Here's an example input message, written as a Python string:

```
"\x00\x00\x00\x05hello"
```

`\x00\x00\x00\x05` -- four bytes representing the number of bytes in the payload

`hello` -- the string `"hello"`

### Output

The outputs of the application are strings followed by newlines. Here's an example output message, written as a Python string:

`olleh\n` -- the string `"olleh"` (`"hello"` reversed)

### Processing

The `decoder` function creates a string from the value represented by the payload. The string is then sent to the `reverse` computation where it is reversed. The reversed string is then sent to the `encoder` function, where a newline is appended to the string before it sent out via the sink.

## Running Reverse

In order to run the application you will need Machida, Giles Sender, Data Receiver, and the Cluster Shutdown tool. We provide instructions for building these tools yourself and we provide prebuilt binaries within a Docker container. Please visit our [setup](https://docs.wallaroolabs.com/book/getting-started/choosing-an-installation-option.html) instructions to choose one of these options if you have not already done so.

You will need five separate shells to run this application (please see [starting a new shell](https://docs.wallaroolabs.com/book/getting-started/starting-a-new-shell.html) for details depending on your installation choice). Open each shell and go to the `examples/python/reverse` directory.

### Shell 1: Metrics

Start up the Metrics UI if you don't already have it running.

```bash
metrics_reporter_ui start
```

You can verify it started up correctly by visiting [http://localhost:4000](http://localhost:4000).

If you need to restart the UI, run the following.

```bash
metrics_reporter_ui restart
```

When it's time to stop the UI, run the following.

```bash
metrics_reporter_ui stop
```

If you need to start the UI after stopping it, run the following.

```bash
metrics_reporter_ui start
```

### Shell 2: Data Receiver

Run Data Receiver to listen for TCP output on `127.0.0.1` port `7002`:

```bash
data_receiver --ponythreads=1 --ponynoblock \
  --listen 127.0.0.1:7002
```

### Shell 3: Reverse

Run `machida` with `--application-module reverse`:

```bash
machida --application-module reverse --in 127.0.0.1:7010 --out 127.0.0.1:7002 \
  --metrics 127.0.0.1:5001 --control 127.0.0.1:6000 --data 127.0.0.1:6001 \
  --name worker-name --external 127.0.0.1:5050 --cluster-initializer \
  --ponythreads=1 --ponynoblock
```

### Shell 4: Sender

Send some messages:

```bash
sender --host 127.0.0.1:7010 --file words.txt \
  --batch-size 5 --interval 100_000_000 --messages 150 --repeat \
  --ponythreads=1 --ponynoblock --no-write
```

## Reading the Output

The output will be printed to the console in the first shell. Each line should be the reverse of a word found in the `words.txt` file.

## Shell 5: Shutdown

You can shut down the cluster with this command at any time:

```bash
cluster_shutdown 127.0.0.1:5050
```

You can shut down Giles Sender and Data Receiver by pressing `Ctrl-c` from their respective shells.

You can shut down the Metrics UI with the following command.

```bash
metrics_reporter_ui stop
```
