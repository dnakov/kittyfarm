import Foundation

enum GeneratedNotice {
    static let androidCodegenCommand = """
    protoc \
      --proto_path=Protos \
      --proto_path=/opt/homebrew/Cellar/protobuf/33.2/include \
      --plugin=protoc-gen-swift=/path/to/protoc-gen-swift \
      --plugin=protoc-gen-grpc-swift=/path/to/protoc-gen-grpc-swift-2 \
      --swift_out=KittyFarm/Generated \
      --grpc-swift_opt=Client=true \
      --grpc-swift_opt=Server=false \
      --grpc-swift_out=KittyFarm/Generated \
      Protos/emulator_controller_kittyfarm.proto
    """
}
